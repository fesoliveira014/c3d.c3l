module c3d::test::lod;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::spatial;
import c3d::render @public;
import c3d::shader;
import std::math;

struct Fixture @private {
    AssetStore assets;
    Scene scene;
    GeometryId geometry;
    MaterialId material;
}

fn void test_lod_view_history_commits_only_submitted_selections() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    LodPart[3] parts = fixture_parts(&fixture);
    LodLevel[2] levels = fixture_levels();
    Node* node = fixture.scene.add_lod_group(&fixture.assets, { .parts = parts[..], .levels = levels[..] })!!;
    fixture.scene.update_world();
    LodGroupState* state = fixture.scene.get(node, LodGroup).state;
    LodHistoryEntry[3] history;
    LodHistory histories = { .entries = history[..], .first = 1 };
    history[0].listed = true;
    history[2].dirty = true;
    history[2].committed.valid = true;
    Camera camera = camera::perspective_deg(60, 0.1f);
    float diameter = 2 * maths::aabb_sphere(state.local_bounds(&fixture.assets)).radius;
    float projection_scale = diameter / (2 * math::tan(camera.fov_y * 0.5f));
    float threshold = levels[0].min_screen_size;
    LodSelection selected = select_fixture_lod(
        fixture: &fixture,
        node: node,
        history: &history[0],
        camera: camera,
        distance: projection_scale / (threshold * 0.9f),
    );
    assert(selected.level == 1 && selected.reject_history && !history[0].committed.valid);
    render::publish_lod_history(&histories);
    assert(history[2].dirty && history[2].committed.valid);
    selected = select_fixture_lod(
        fixture: &fixture,
        node: node,
        history: &history[0],
        camera: camera,
        distance: projection_scale / (threshold * 1.05f),
    );
    assert(selected.level == 1 && !selected.reject_history);
    selected = select_fixture_lod(
        fixture: &fixture,
        node: node,
        history: &history[0],
        camera: camera,
        distance: projection_scale / (threshold * 1.5f),
    );
    assert(selected.level == 0 && selected.reject_history);
    render::discard_lod_history(&histories);
    assert(history[2].dirty);
    selected = select_fixture_lod(
        fixture: &fixture,
        node: node,
        history: &history[0],
        camera: camera,
        distance: projection_scale / (threshold * 1.05f),
    );
    assert(selected.level == 1 && !selected.reject_history);

    fixture.scene.remove_component(node, LodGroup);
    fixture.scene.add(node, scene::create_lod_group(mem, &fixture.assets, { .parts = parts[..], .levels = levels[..] })!!);
    selected = select_fixture_lod(
        fixture: &fixture,
        node: node,
        history: &history[0],
        camera: camera,
        distance: projection_scale / (threshold * 1.05f),
    );
    assert(selected.level == 0 && selected.reject_history);
    render::publish_lod_history(&histories);
    render::reset_lod_history(&histories);
    assert(!history[0].committed.valid && !history[0].dirty);
    assert(history[2].dirty && history[2].committed.valid);
}

fn void test_lod_bias_uses_normalized_existing_projection() @test {
    Camera perspective = camera::perspective_deg(60, 0.1f);
    Sphere sphere = { .center = { 2, 0, -10 }, .radius = 1 };
    float base = render::lod_screen_size(
        camera: perspective,
        camera_position: {},
        bounds: sphere,
        bias: 0,
    );
    foreach (float height : { 256.0f, 1080.0f, 2160.0f }) {
        float expected = camera::projected_size(
            camera: perspective,
            camera_position: {},
            bounds: sphere,
            output_height: height,
        ) / height;
        assert(math::abs(base - expected) < 0.000001f);
    }
    assert(math::abs(render::lod_screen_size(
        camera: perspective,
        camera_position: {},
        bounds: sphere,
        bias: 1,
    ) - 2 * base) < 0.000001f);
    assert(math::abs(render::lod_screen_size(
        camera: perspective,
        camera_position: {},
        bounds: sphere,
        bias: -1,
    ) - base * 0.5f) < 0.000001f);
    Camera orthographic = perspective;
    orthographic.projection = Projection.ORTHOGRAPHIC;
    orthographic.ortho_height = 10;
    assert(math::abs(render::lod_screen_size(
        camera: orthographic,
        camera_position: {},
        bounds: sphere,
        bias: 0,
    ) - 0.2f) < 0.000001f);
    assert(render::lod_screen_size(
        camera: orthographic,
        camera_position: { 100, 200, 300 },
        bounds: sphere,
        bias: 0,
    )
      == render::lod_screen_size(
          camera: orthographic,
          camera_position: {},
          bounds: sphere,
          bias: 0,
      ));
    assert(render::lod_screen_size(
        camera: perspective,
        camera_position: sphere.center,
        bounds: sphere,
        bias: -float::max,
    ) == float::inf);
    assert(render::lod_screen_size(
        camera: perspective,
        camera_position: {},
        bounds: {},
        bias: float::max,
    ) == 0);
    Renderer* renderer = mem::new(Renderer);
    defer free(renderer);
    ViewDesc desc = render::default_view_desc();
    foreach (float bias : { float::nan, float::inf, -float::inf }) {
        desc.lod_bias = bias;
        assert(@catch(render::validate_view_desc(renderer, &desc)) == c3d::INVALID_ARGUMENT);
    }
}

fn LodSelection select_fixture_lod(
    Fixture* fixture,
    Node* node,
    LodHistoryEntry* history,
    Camera camera,
    float distance,
) @private {
    return render::select_lod_group(
        history: history,
        scene: &fixture.scene,
        assets: &fixture.assets,
        node: node,
        state: fixture.scene.get(node, LodGroup).state,
        camera: camera,
        camera_position: { 0, 0, distance },
        bias: 0,
    );
}

fn void test_lod_selection_and_hysteresis() @test {
    float[3] sizes = { 0.2f, 0.05f, 0 };
    assert(scene::select_lod_level(
        screen_size: 0.3f,
        min_screen_sizes: sizes[..],
        previous: 0,
        history_valid: false,
    ) == 0);
    assert(scene::select_lod_level(
        screen_size: 0.1f,
        min_screen_sizes: sizes[..],
        previous: 0,
        history_valid: false,
    ) == 1);
    assert(scene::select_lod_level(
        screen_size: 0,
        min_screen_sizes: sizes[..],
        previous: 0,
        history_valid: false,
    ) == 2);
    assert(scene::select_lod_level(
        screen_size: 0.2f,
        min_screen_sizes: sizes[..],
        previous: 0,
        history_valid: false,
    ) == 0);
    assert(scene::select_lod_level(
        screen_size: 0.199f,
        min_screen_sizes: sizes[..],
        previous: 0,
        history_valid: true,
    ) == 1);
    assert(scene::select_lod_level(
        screen_size: 0.21f,
        min_screen_sizes: sizes[..],
        previous: 1,
        history_valid: true,
    ) == 1);
    assert(scene::select_lod_level(
        screen_size: 0.221f,
        min_screen_sizes: sizes[..],
        previous: 1,
        history_valid: true,
    ) == 0);
    assert(scene::select_lod_level(
        screen_size: 0.01f,
        min_screen_sizes: sizes[..],
        previous: 0,
        history_valid: true,
    ) == 2);
    assert(scene::select_lod_level(
        screen_size: 1,
        min_screen_sizes: sizes[..],
        previous: 2,
        history_valid: true,
    ) == 0);
}

fn void test_lod_copies_descriptors_and_placements() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    LodPart[3] parts = {
        { .geometry = fixture.geometry, .material = fixture.material, .local = maths::TRANSFORM_IDENTITY.to_mat4() },
        { .geometry = fixture.geometry, .material = fixture.material, .local = maths::TRANSFORM_IDENTITY.to_mat4() },
        { .geometry = fixture.geometry, .material = fixture.material, .local = maths::TRANSFORM_IDENTITY.to_mat4() },
    };
    LodLevel[2] levels = {
        { .first_part = 0, .part_count = 2, .min_screen_size = 0.2f },
        { .first_part = 2, .part_count = 1, .min_screen_size = 0 },
    };
    Transform[2] placements = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    placements[1].position.x = 4;
    Node* node = fixture.scene.add_instanced_lod_group(
        assets: &fixture.assets,
        desc: { .levels = levels[..], .parts = parts[..] },
        capacity: 4,
        transforms: placements[..],
    )!!;
    placements[1].position.x = 20;
    levels[0].part_count = 1;
    parts[0].geometry = {};
    LodGroupState* state = fixture.scene.get(node, LodGroup).state;
    assert(state.desc.levels[0].part_count == 2);
    assert(c3d::same_id(state.desc.parts[0].geometry, fixture.geometry));
    assert(state.transforms[1].position.x == 4);
    assert(state.transforms.len == 4 && state.colors.len == 4 && state.count == 2);
    assert(state.colors[1] == (Vec4){ 1, 1, 1, 1 });
    assert(fixture.scene.count(InstancedMesh) == 0);

    ulong epoch = state.instance_epoch;
    uint revision = state.revision;
    state.transforms[0].position.x = 2;
    fixture.scene.mark_lod_instances_dirty(node);
    assert(state.instance_epoch == epoch && state.revision != revision);
    fixture.scene.set_lod_instances(node, placements[..])!!;
    assert(state.instance_epoch != epoch);
    fixture.scene.resize_lod_instances(node, 1)!!;
    uint survivor = state.slot_generations[0];
    uint retired = state.slot_generations[1];
    fixture.scene.resize_lod_instances(node, 3)!!;
    assert(state.slot_generations[0] == survivor && state.slot_generations[1] != retired);
    assert(state.transforms[1].position == (Vec3){});
    assert(state.transforms[1].scale == (Vec3){ 1, 1, 1 });
    assert(state.colors[1] == (Vec4){ 1, 1, 1, 1 });

    if (catch excuse = fixture.scene.resize_lod_instances(node, 5)) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false);
    }
    assert(state.count == 3);
    epoch = state.instance_epoch;
    revision = state.revision;
    Aabb bounds = state.placement_bounds(&fixture.assets);
    uint aggregate_revision = state.aggregate_revision;
    for (uint step = 0; step < 10; step++) {
        LodEffects effects = state.effects;
        effects.sway.direction = { 1, 0, 0 };
        effects.sway.amplitude = (float)step * 0.1f;
        fixture.scene.set_lod_effects(node, effects);
        assert(state.instance_epoch == epoch && state.revision == revision);
        assert(state.aggregate_revision == aggregate_revision);
        Aabb current = state.placement_bounds(&fixture.assets);
        assert(current.min == bounds.min && current.max == bounds.max);
    }
    state.transforms[0].position.x = 40;
    fixture.scene.publish_lod_instances(node, 1);
    assert(state.count == 1 && state.instance_epoch != epoch && state.revision != revision);
    assert(state.placement_bounds(&fixture.assets).max.x > bounds.max.x);
}

fn void test_lod_gpu_records_keep_logical_indices_after_parity_changes() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    LodPart[3] parts = fixture_parts(&fixture);
    LodLevel[2] levels = fixture_levels();
    Transform[4] placements;
    placements[..] = maths::TRANSFORM_IDENTITY;
    placements[0].scale.x = -1;
    placements[2].scale.z = -1;
    foreach (index, &placement : placements) placement.position.x = (float)index * 3;
    Node* node = fixture.scene.add_instanced_lod_group(
        assets: &fixture.assets,
        desc: { .parts = parts[..], .levels = levels[..] },
        capacity: 4,
        transforms: placements[..],
    )!!;
    node.local.position.z = -10;
    fixture.scene.update_world();
    LodGroupState* state = fixture.scene.get(node, LodGroup).state;
    InstanceGpu[4] records;
    LodMetadataGpu[4] metadata;
    uint[4] unmirrored;
    uint[4] mirrored;
    uint split = render::pack_lod_records(
        records: records[..],
        metadata: metadata[..],
        unmirrored: unmirrored[..],
        mirrored: mirrored[..],
        world: node.world,
        state: state,
    );
    assert(split == 2 && unmirrored[0] == 1 && unmirrored[1] == 3);
    assert(mirrored[0] == 0 && mirrored[1] == 2);
    foreach (index, record : records) {
        assert(bitcast(record.model, Mat4) == node.world.mul(placements[index].to_mat4()));
        assert(metadata[index].generation == state.slot_generations[index]);
    }
    uint generation = metadata[0].generation;
    state.transforms[0].scale.x = 1;
    state.transforms[0].position.x = 17;
    fixture.scene.mark_lod_instances_dirty(node);
    split = render::pack_lod_records(
        records: records[..],
        metadata: metadata[..],
        unmirrored: unmirrored[..],
        mirrored: mirrored[..],
        world: node.world,
        state: state,
    );
    assert(split == 3 && unmirrored[0] == 0 && mirrored[0] == 2);
    assert(metadata[0].generation == generation && metadata[0].parity == 0);
    assert(bitcast(records[0].model, Mat4).m03 == 17);
}

fn void test_lod_rejects_malformed_ranges_before_adding_nodes() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    LodPart[1] parts = {
        { .geometry = fixture.geometry, .material = fixture.material, .local = maths::TRANSFORM_IDENTITY.to_mat4() },
    };
    LodLevel[1] levels = { { .first_part = 1, .part_count = 1, .min_screen_size = 0 } };
    if (catch excuse = fixture.scene.add_lod_group(&fixture.assets, { .levels = levels[..], .parts = parts[..] })) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false);
    }
    assert(fixture.scene.count(LodGroup) == 0);
    levels[0].first_part = 0;
    parts[0].geometry = {};
    if (catch excuse = fixture.scene.add_lod_group(&fixture.assets, { .levels = levels[..], .parts = parts[..] })) {
        assert(excuse == c3d::INVALID_ID);
    } else {
        assert(false);
    }
    assert(fixture.scene.count(LodGroup) == 0);
}

fn void test_lod_bounds_cover_all_levels_and_geometry_edits() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    LodPart[3] parts = fixture_parts(&fixture);
    parts[2].local = matrix::IDENTITY4.scale({ 8, 1, 1 });
    LodLevel[2] levels = fixture_levels();
    LodDesc desc = { .levels = levels[..], .parts = parts[..] };
    Node* ordinary = fixture.scene.add_lod_group(&fixture.assets, desc)!!;
    Transform[2] placements = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    placements[1].position.x = 10;
    Node* batch = fixture.scene.add_instanced_lod_group(
        assets: &fixture.assets,
        desc: desc,
        capacity: 2,
        transforms: placements[..],
    )!!;
    fixture.scene.update_world();
    LodGroup* group = fixture.scene.get(ordinary, LodGroup);
    Aabb bounds = spatial::lod_world_bounds(&fixture.assets, ordinary, group);
    assert(bounds.min.x == -4 && bounds.max.x == 4);
    uint revision = group.state.bounds_revision;
    bounds = spatial::lod_world_bounds(&fixture.assets, ordinary, group);
    assert(group.state.bounds_revision == revision);
    bounds = spatial::lod_world_bounds(&fixture.assets, batch, fixture.scene.get(batch, LodGroup));
    assert(bounds.min.x == -4 && bounds.max.x == 14);

    fixture.assets.geometry(fixture.geometry).data.bounds = { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } };
    fixture.assets.mark_geometry_dirty(fixture.geometry);
    bounds = spatial::lod_world_bounds(&fixture.assets, ordinary, group);
    assert(bounds.min.x == -8 && bounds.max.x == 8);
    assert(group.state.bounds_revision != revision);
    Sphere sphere = maths::aabb_sphere(bounds);
    for (uint corner = 0; corner < 8; corner++) {
        Vec3 point = {
            corner & 1 ? bounds.max.x : bounds.min.x,
            corner & 2 ? bounds.max.y : bounds.min.y,
            corner & 4 ? bounds.max.z : bounds.min.z,
        };
        assert(point.distance(sphere.center) <= sphere.radius + 1e-5f);
    }
}

fn void test_lod_base_queries_match_index_and_trace_parts() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    LodPart[3] parts = fixture_parts(&fixture);
    parts[2].geometry = fixture.assets.add_geometry(&fixture.assets.geometry(fixture.geometry).data)!!;
    parts[1].local = parts[1].local.scale({ -1, 1, 1 });
    LodLevel[2] levels = fixture_levels();
    Transform[3] placements = { maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY, maths::TRANSFORM_IDENTITY };
    placements[1].position.x = 10;
    placements[1].scale.x = -1;
    placements[2].position.x = 20;
    Node* node = fixture.scene.add_instanced_lod_group(
        assets: &fixture.assets,
        desc: { .levels = levels[..], .parts = parts[..] },
        capacity: 3,
        transforms: placements[..],
    )!!;
    node.local.position.z = -10;
    fixture.scene.update_world();
    SceneIndex small = spatial::create_scene_index(mem, 5);
    defer spatial::destroy_scene_index(&small);
    assert(@catch(small.refresh(&fixture.assets, &fixture.scene)) == c3d::CAPACITY_EXCEEDED);
    assert(small.count == 0);
    SceneIndex index = spatial::create_scene_index(mem, 6);
    defer spatial::destroy_scene_index(&index);
    index.refresh(&fixture.assets, &fixture.scene)!!;
    assert(index.count == 6);
    uint revision = index.revision;
    index.refresh(&fixture.assets, &fixture.scene)!!;
    assert(index.revision == revision);
    @pool() {
        for (uint part = 0; part < 2; part++) {
            Ray ray = { .origin = { part ? 2 : -2, 0, 0 }, .direction = { 0, 0, -1 } };
            PickOptions options = spatial::PICK_OPTIONS_DEFAULT;
            options.precision = PickPrecision.TRIANGLES;
            PickHit[] direct = spatial::pick(
                allocator: tmem,
                assets: &fixture.assets,
                scene: &fixture.scene,
                ray: ray,
                options: options,
            );
            PickHit[] indexed = index.pick(
                allocator: tmem,
                assets: &fixture.assets,
                ray: ray,
                options: options,
            );
            assert(direct.len == 1 && indexed.len == 1);
            assert(direct[0].lod_group && direct[0].part_index == part && direct[0].instance_index == 0);
            assert(c3d::same_id(direct[0].geometry, fixture.geometry));
            assert(direct[0].triangle_hit && indexed[0].triangle_hit);
            assert(direct[0].part_index == indexed[0].part_index && direct[0].distance == indexed[0].distance);
            assert(math::abs(direct[0].barycentric.x + direct[0].barycentric.y + direct[0].barycentric.z - 1) < 1e-5f);
        }
        PickHit[] centre = spatial::pick(
            allocator: tmem,
            assets: &fixture.assets,
            scene: &fixture.scene,
            ray: { .origin = {}, .direction = { 0, 0, -1 } },
            options: { .precision = PickPrecision.TRIANGLES, .faces = PickFaces.BOTH, .layers = uint::max },
        );
        assert(centre.len == 0);
        uint dangling;
        render::TraceInstance[] records = render::collect_trace_instances(
            allocator: tmem,
            scene: &fixture.scene,
            assets: &fixture.assets,
            dangling: &dangling,
        );
        assert(records.len == 6 && dangling == 0);
        foreach (record : records) {
            assert(record.lod_identity == fixture.scene.get(node, LodGroup).state.identity);
            Mat4 expected = node.world.mul(placements[record.instance_index].to_mat4()).mul(parts[record.part_index].local);
            Mat4 actual = render::trace_instance_world(&record);
            assert(mem::equals(&actual, &expected, Mat4::size));
        }
        fixture.assets.geometry(parts[2].geometry).data.bounds.max.x += 1;
        fixture.assets.mark_geometry_dirty(parts[2].geometry);
        render::TraceInstance[] unchanged = render::collect_trace_instances(
            allocator: tmem,
            scene: &fixture.scene,
            assets: &fixture.assets,
            dangling: &dangling,
        );
        assert(unchanged.len == records.len);
        assert(mem::equals(records.ptr, unchanged.ptr, records.len * render::TraceInstance::size));
        fixture.assets.mark_geometry_dirty(fixture.geometry);
        render::TraceInstance[] changed = render::collect_trace_instances(
            allocator: tmem,
            scene: &fixture.scene,
            assets: &fixture.assets,
            dangling: &dangling,
        );
        assert(changed.len == records.len && changed[0].geometry_revision != records[0].geometry_revision);
        fixture.scene.get(node, LodGroup).state.effects.trace = false;
        records = render::collect_trace_instances(
            allocator: tmem,
            scene: &fixture.scene,
            assets: &fixture.assets,
            dangling: &dangling,
        );
        assert(records.len == 0);
    };
    fixture.assets.remove_geometry(fixture.geometry);
    index.refresh(&fixture.assets, &fixture.scene)!!;
    assert(index.count == 0 && index.dangling == 1);
}

fn void test_lod_validation_is_atomic_and_removal_releases_storage() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    LodPart[3] parts = fixture_parts(&fixture);
    LodLevel[2] levels = fixture_levels();
    LodDesc desc = { .levels = levels[..], .parts = parts[..] };
    {
        Scene owned = scene::create_scene(&tracker, { .max_nodes = 1 });
        defer scene::destroy_scene(&owned);
        sz before = tracker.allocated();
        levels[0].min_screen_size = bitcast(0x7fc00000u, float);
        assert(@catch(owned.add_lod_group(&fixture.assets, desc)) == c3d::INVALID_ARGUMENT);
        levels[0].min_screen_size = 0.2f;
        parts[0].local.m00 = 0;
        assert(@catch(owned.add_lod_group(&fixture.assets, desc)) == c3d::INVALID_ARGUMENT);
        parts[0].local.m00 = 1;
        Node* node = owned.add_instanced_lod_group(assets: &fixture.assets, desc: desc, capacity: 3)!!;
        LodGroupState* state = owned.get(node, LodGroup).state;
        ulong identity = state.identity;
        Transform[1] invalid = { maths::TRANSFORM_IDENTITY };
        invalid[0].scale.x = 0;
        uint revision = state.revision;
        assert(@catch(owned.set_lod_instances(node, invalid[..])) == c3d::INVALID_ARGUMENT);
        assert(state.count == 0 && state.revision == revision);
        owned.remove(node);
        assert(tracker.allocated() == before);
        node = owned.add_lod_group(&fixture.assets, desc)!!;
        assert(owned.get(node, LodGroup).state.identity != identity);
        owned.remove(node);
    }
    assert(!tracker.has_leaks());
}

fn void test_lod_asset_edits_invalidate_the_whole_group() @test {
    Fixture fixture = make_fixture();
    defer destroy_fixture(&fixture);
    LodPart[3] parts = fixture_parts(&fixture);
    LodLevel[2] levels = fixture_levels();
    LodDesc desc = { .parts = parts[..], .levels = levels[..] };
    Node* node = fixture.scene.add_instanced_lod_group(assets: &fixture.assets, desc: desc, capacity: 1)!!;
    LodGroup* group = fixture.scene.get(node, LodGroup);
    assert(spatial::lod_group_is_live(&fixture.assets, group));
    fixture.assets.geometry(fixture.geometry).target_count = 1;
    assert(!spatial::lod_group_is_live(&fixture.assets, group));
    fixture.assets.geometry(fixture.geometry).target_count = 0;
    char[1] bytes = { 1 };
    ShaderDesc shader_desc = { .fragment = bytes[..] };
    ShaderId shader = fixture.assets.add_shader(&shader_desc)!!;
    fixture.assets.material(fixture.material).data = material::custom(shader, {});
    assert(spatial::lod_group_is_live(&fixture.assets, group));
    shader_desc.vertex = { .shaded = bytes[..], .depth = bytes[..] };
    fixture.assets.replace_shader(shader, &shader_desc)!!;
    assert(!spatial::lod_group_is_live(&fixture.assets, group));
    fixture.scene.remove(node);
    desc.has_bounds_override = true;
    desc.local_bounds = { .min = { -3, -1, -1 }, .max = { 3, 1, 1 } };
    assert(@catch(fixture.scene.add_instanced_lod_group(assets: &fixture.assets, desc: desc, capacity: 1)) == c3d::UNSUPPORTED);
    shader_desc.vertex.instanced_shaded = bytes[..];
    shader_desc.vertex.instanced_depth = bytes[..];
    fixture.assets.replace_shader(shader, &shader_desc)!!;
    node = fixture.scene.add_instanced_lod_group(assets: &fixture.assets, desc: desc, capacity: 1)!!;
    group = fixture.scene.get(node, LodGroup);
    assert(spatial::lod_group_is_live(&fixture.assets, group));
    fixture.assets.remove_shader(shader);
    assert(!spatial::lod_group_is_live(&fixture.assets, group));
}

fn LodPart[3] fixture_parts(Fixture* fixture) @local {
    return {
        { .geometry = fixture.geometry, .material = fixture.material, .local = matrix::IDENTITY4.translate({ -2, 0, 0 }) },
        { .geometry = fixture.geometry, .material = fixture.material, .local = matrix::IDENTITY4.translate({ 2, 0, 0 }) },
        { .geometry = fixture.geometry, .material = fixture.material, .local = matrix::IDENTITY4 },
    };
}

fn LodLevel[2] fixture_levels() @local {
    return {
        { .first_part = 0, .part_count = 2, .min_screen_size = 0.2f },
        { .first_part = 2, .part_count = 1, .min_screen_size = 0 },
    };
}

fn Fixture make_fixture() @private {
    Fixture fixture;
    fixture.assets = asset::create_asset_store(mem, {
        .max_geometries = 2,
        .max_textures = asset::BUILTIN_TEXTURE_COUNT,
        .max_materials = 4,
        .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
        .max_shaders = 1,
    });
    @pool() {
        Geometry geometry = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        fixture.geometry = fixture.assets.add_geometry(&geometry)!!;
    };
    fixture.material = fixture.assets.add_material(material::basic({ .color = { 1, 1, 1, 1 } }))!!;
    fixture.scene = scene::create_scene(mem, { .max_nodes = 8 });
    return fixture;
}

fn void destroy_fixture(Fixture* fixture) @private {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}
