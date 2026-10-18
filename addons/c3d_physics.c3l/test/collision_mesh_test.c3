module c3d_physics_collide_test;

import c3d;
import std::math;
import b3;

const float FOLD_HALF_SIZE @private = 4;
const float FOLD_RAISE @private = 0.8f; // corner D rises, giving the second triangle a slope of RAISE / (2 * HALF_SIZE)
const Vec3 FOLD_RAMP_NORMAL @private = { -0.0990148f, 0.9901476f, 0.0990148f }; // normalised (-0.1, 1, 0.1)
const uint RAMP_SEGMENTS @private = 4;
const float RAMP_SEGMENT_RUN @private = 2;
const float RAMP_SLOPE @private = 0.5f;
const float RAMP_HALF_WIDTH @private = 2;
const Vec3 RAMP_NORMAL @private = { -0.4472136f, 0.8944272f, 0 }; // normalised (-0.5, 1, 0)
const float DROP_COLUMN @private = 4; // ramp run where the probe falls onto the surface
const float DROP_START_HEIGHT @private = 4;
const float DROP_DISTANCE @private = 4; // probe travel when only the probe moves
const float MESH_RISE @private = 2; // mesh travel when only the mesh moves, the same relative motion as half the drop
const float HOVER_GAP @private = 0.01f; // inside the native speculative margin of four linear slops
const float BAND_OVERLAP @private = 0.01f; // starting overlap that puts a cast inside the native closing band
const float RAY_COLUMN @private = 3;
const float RAY_DROP @private = 3.5f; // ray origin height above the surface
const float RAY_LENGTH @private = 10;
const uint HEXAGON_SIDES @private = 6;
const float TINY_TRIANGLE_SIDE @private = 0.0005f; // area 1.25e-7, under the native cook tolerance of 2.5e-7

struct MeshQueryFixture @private {
    AssetStore assets;
    CollisionCache cache;
    GeometryId plane;
    GeometryId fold;
    GeometryId ramp;
    GeometryId prism;
}

fn GeometryId add_mesh_geometry(AssetStore* assets, Vec3[] positions, uint[] indices) @private {
    Geometry geometry = { .positions = positions, .indices = indices };
    geometry.finalize();
    return assets.add_geometry(&geometry)!!;
}

fn GeometryId add_plane_triangle(AssetStore* assets) @private {
    Vec3[3] corners = {
        { -FOLD_HALF_SIZE, 0, -FOLD_HALF_SIZE },
        { -FOLD_HALF_SIZE, 0, FOLD_HALF_SIZE },
        { FOLD_HALF_SIZE, 0, -FOLD_HALF_SIZE },
    };
    uint[3] winding = { 0, 1, 2 };
    return add_mesh_geometry(assets, corners[..], winding[..]);
}

fn GeometryId add_fold(AssetStore* assets) @private {
    Vec3[4] corners = {
        { -FOLD_HALF_SIZE, 0, -FOLD_HALF_SIZE },
        { -FOLD_HALF_SIZE, 0, FOLD_HALF_SIZE },
        { FOLD_HALF_SIZE, 0, FOLD_HALF_SIZE },
        { FOLD_HALF_SIZE, FOLD_RAISE, -FOLD_HALF_SIZE },
    };
    uint[6] winding = { 0, 1, 2, 0, 2, 3 };
    return add_mesh_geometry(assets, corners[..], winding[..]);
}

fn GeometryId add_ramp(AssetStore* assets) @private {
    Vec3[(RAMP_SEGMENTS + 1) * 2] positions;
    uint[RAMP_SEGMENTS * 6] winding;

    for (uint column = 0; column <= RAMP_SEGMENTS; column++) {
        float run = (float)column * RAMP_SEGMENT_RUN;
        positions[2 * column] = { run, RAMP_SLOPE * run, -RAMP_HALF_WIDTH };
        positions[2 * column + 1] = { run, RAMP_SLOPE * run, RAMP_HALF_WIDTH };
    }

    for (uint segment = 0; segment < RAMP_SEGMENTS; segment++) {
        uint near_back = 2 * segment;
        uint near_front = near_back + 1;
        uint far_back = near_back + 2;
        uint far_front = near_back + 3;
        uint[6] quad = { near_back, near_front, far_front, near_back, far_front, far_back };
        winding[6 * segment:6] = quad[..];
    }

    return add_mesh_geometry(assets, positions[..], winding[..]);
}

fn GeometryId add_prism(AssetStore* assets) @private {
    GeometryId id;
    @pool() {
        id = add_mesh_geometry(assets, query_prism_points(HEXAGON_SIDES), {});
    };
    return id;
}

fn void setup_mesh_queries(MeshQueryFixture* fixture, Allocator allocator = mem) @private {
    fixture.assets = asset::create_asset_store(allocator, asset::default_asset_store_desc());
    fixture.cache = physics::create_collision_cache(
        allocator: allocator,
        assets: &fixture.assets,
        desc: physics::default_collision_cache_desc(),
    )!!;

    fixture.plane = add_plane_triangle(&fixture.assets);
    fixture.fold = add_fold(&fixture.assets);
    fixture.ramp = add_ramp(&fixture.assets);
    fixture.prism = add_prism(&fixture.assets);
}

fn void teardown_mesh_queries(MeshQueryFixture* fixture) @private {
    physics::destroy_collision_cache(&fixture.cache)!!;
    asset::destroy_asset_store(&fixture.assets);
}

fn CollisionShape mesh_shape(
    CollisionCache* cache,
    GeometryId geometry,
    Vec3 scale = { 1, 1, 1 },
    Allocator allocator = mem,
) @private {
    CollisionShapeDesc desc = scaled_shape_desc(MESH, scale);
    desc.geometry = geometry;
    return physics::create_collision_shape(allocator, cache, desc)!!;
}

fn CollisionShape prism_shape(CollisionCache* cache, GeometryId geometry, Allocator allocator = mem) @private {
    CollisionShapeDesc desc = scaled_shape_desc(HULL, { 1, 1, 1 });
    desc.geometry = geometry;
    return physics::create_collision_shape(allocator, cache, desc)!!;
}

fn float drop_stop_height() @private => RAMP_SLOPE * DROP_COLUMN + (PROBE_RADIUS - LINEAR_SLOP) / RAMP_NORMAL.y;

fn Vec3 drop_stop_witness() @private {
    float closing = PROBE_RADIUS - LINEAR_SLOP;
    return { DROP_COLUMN - RAMP_NORMAL.x * closing, drop_stop_height() - RAMP_NORMAL.y * closing, 0 };
}

fn maths::Transform surface_pose() @private => posed({ 3, -2, 4 }, rotated());

fn Vec3 surface_point(maths::Transform pose, Vec3 local) @private => pose.position + pose.rotation.rotate_vec3(local);

fn void test_mesh_contacts_press_a_sphere_into_a_plane_triangle() @test {
    MeshQueryFixture fixture;
    setup_mesh_queries(&fixture);
    defer teardown_mesh_queries(&fixture);

    CollisionShape surface = mesh_shape(&fixture.cache, fixture.plane);
    defer physics::destroy_collision_shape(&surface);
    CollisionShape probe = probe_sphere(mem, &fixture.cache);
    defer physics::destroy_collision_shape(&probe);

    maths::Transform pose = surface_pose();
    float depth = 0.1f;
    maths::Transform probe_pose = posed(surface_point(pose, { -1, PROBE_RADIUS - depth, -1 }));
    Vec3 up = pose.rotation.rotate_vec3({ 0, 1, 0 });
    Vec3 midpoint = surface_point(pose, { -1, -depth / 2, -1 });

    CollisionContact[collide::MAX_MANIFOLD_POINTS] contacts;
    usz count = surface.view().contacts(
        pose_a: pose,
        other: probe.view(),
        pose_b: probe_pose,
        output: contacts[..],
    )!!;
    assert(count == 1);
    assert(near(contacts[0].separation, -depth, LOOSE));
    assert(near_vector(contacts[0].normal, up, LOOSE));
    assert(near_vector(contacts[0].point, midpoint, LOOSE));
    assert(contacts[0].triangle_index == 0);

    count = probe.view().contacts(
        pose_a: probe_pose,
        other: surface.view(),
        pose_b: pose,
        output: contacts[..],
    )!!;
    assert(count == 1);
    assert(near(contacts[0].separation, -depth, LOOSE));
    assert(near_vector(contacts[0].normal, -up, LOOSE));
    assert(near_vector(contacts[0].point, midpoint, LOOSE));
    assert(contacts[0].triangle_index == 0);

    maths::Transform hovering = posed(surface_point(pose, { -1, PROBE_RADIUS + HOVER_GAP, -1 }));
    count = surface.view().contacts(
        pose_a: pose,
        other: probe.view(),
        pose_b: hovering,
        output: contacts[..],
    )!!;
    assert(count == 1);
    assert(near(contacts[0].separation, HOVER_GAP, LOOSE));
}

fn void test_mesh_contacts_report_every_native_hull_point_on_each_triangle() @test {
    MeshQueryFixture fixture;
    setup_mesh_queries(&fixture);
    defer teardown_mesh_queries(&fixture);

    CollisionShape surface = mesh_shape(&fixture.cache, fixture.fold);
    defer physics::destroy_collision_shape(&surface);
    CollisionShape prism = prism_shape(&fixture.cache, fixture.prism);
    defer physics::destroy_collision_shape(&prism);
    CollisionShapeDesc box_desc = scaled_shape_desc(BOX, { 1, 1, 1 });
    box_desc.half_extents = { 0.5f, 0.1f, 0.5f };
    CollisionShape box = physics::create_collision_shape(mem, &fixture.cache, box_desc)!!;
    defer physics::destroy_collision_shape(&box);

    maths::Transform pose = surface_pose();
    CollisionContact[16] contacts;

    maths::Transform on_flat = posed(surface_point(pose, { -1, 0, 1 }), pose.rotation);
    usz count = surface.view().contacts(
        pose_a: pose,
        other: prism.view(),
        pose_b: on_flat,
        output: contacts[..],
    )!!;
    assert(count == HEXAGON_SIDES);
    foreach (contact : contacts[:count]) {
        assert(near_vector(contact.normal, pose.rotation.rotate_vec3({ 0, 1, 0 }), LOOSE));
        assert(near(contact.separation, -0.01f, LOOSE));
        assert(contact.triangle_index == contacts[0].triangle_index);
    }

    maths::Transform astride = posed(surface_point(pose, { 0, 0.1f, 0 }), pose.rotation);
    count = surface.view().contacts(
        pose_a: pose,
        other: box.view(),
        pose_b: astride,
        output: contacts[..],
    )!!;
    assert(count > collide::MAX_MANIFOLD_POINTS);

    Vec3 flat_normal = pose.rotation.rotate_vec3({ 0, 1, 0 });
    Vec3 ramp_normal = pose.rotation.rotate_vec3(FOLD_RAMP_NORMAL);
    bool[2] seen;
    foreach (contact : contacts[:count]) {
        assert(contact.triangle_index < 2);
        seen[contact.triangle_index] = true;
        assert(near_vector(contact.normal, flat_normal, LOOSE) || near_vector(contact.normal, ramp_normal, LOOSE));
    }
    assert(seen[0] && seen[1]);
}

fn void test_mesh_distance_is_the_global_minimum_and_zero_on_overlap() @test {
    MeshQueryFixture fixture;
    setup_mesh_queries(&fixture);
    defer teardown_mesh_queries(&fixture);

    CollisionShape surface = mesh_shape(&fixture.cache, fixture.ramp);
    defer physics::destroy_collision_shape(&surface);
    CollisionShape probe = probe_sphere(mem, &fixture.cache);
    defer physics::destroy_collision_shape(&probe);

    maths::Transform pose = surface_pose();
    float length = RAMP_SEGMENTS * RAMP_SEGMENT_RUN;
    float crest = RAMP_SLOPE * length;
    float beyond = 4;

    maths::Transform past_the_crest = posed(surface_point(pose, { length + beyond, crest, 0 }));
    collide::Distance found = probe.view().distance(
        pose_a: past_the_crest,
        other: surface.view(),
        pose_b: pose,
    )!!;
    assert(near(found.distance, beyond - PROBE_RADIUS, LOOSE));
    assert(near_vector(found.point_a, surface_point(pose, { length + beyond - PROBE_RADIUS, crest, 0 }), LOOSE));
    assert(near_vector(found.point_b, surface_point(pose, { length, crest, 0 }), LOOSE));
    assert(near_vector(found.normal, pose.rotation.rotate_vec3({ -1, 0, 0 }), LOOSE));

    maths::Transform inside = posed(surface_point(pose, { 3, RAMP_SLOPE * 3 + 0.1f, 0 }));
    found = probe.view().distance(
        pose_a: inside,
        other: surface.view(),
        pose_b: pose,
    )!!;
    assert(found.distance == 0);
}

fn void test_mesh_casts_close_on_the_surface_with_either_side_moving() @test {
    MeshQueryFixture fixture;
    setup_mesh_queries(&fixture);
    defer teardown_mesh_queries(&fixture);

    CollisionShape surface = mesh_shape(&fixture.cache, fixture.ramp);
    defer physics::destroy_collision_shape(&surface);
    CollisionShape probe = probe_sphere(mem, &fixture.cache);
    defer physics::destroy_collision_shape(&probe);

    maths::Transform pose = surface_pose();
    maths::Transform probe_pose = posed(surface_point(pose, { DROP_COLUMN, DROP_START_HEIGHT, 0 }));
    Vec3 stop_witness = surface_point(pose, drop_stop_witness());
    Vec3 toward_mesh = -pose.rotation.rotate_vec3(RAMP_NORMAL);
    float closing_travel = DROP_START_HEIGHT - drop_stop_height();

    collide::Impact found = probe.view().cast(
        pose_a: probe_pose,
        other: surface.view(),
        pose_b: pose,
        translation_a: pose.rotation.rotate_vec3({ 0, -DROP_DISTANCE, 0 }),
        translation_b: {},
    )!!;
    assert(near(found.time, closing_travel / DROP_DISTANCE, LOOSE));
    assert(near_vector(found.point, stop_witness, LOOSE));
    assert(near_vector(found.normal, toward_mesh, LOOSE));

    float rising_time = closing_travel / MESH_RISE;
    Vec3 mesh_move = pose.rotation.rotate_vec3({ 0, MESH_RISE, 0 });
    found = probe.view().cast(
        pose_a: probe_pose,
        other: surface.view(),
        pose_b: pose,
        translation_a: {},
        translation_b: mesh_move,
    )!!;
    assert(near(found.time, rising_time, LOOSE));
    assert(near_vector(found.point, stop_witness + mesh_move * rising_time, LOOSE));
    assert(near_vector(found.normal, toward_mesh, LOOSE));

    Vec3 common = pose.rotation.rotate_vec3({ 0.5f, 1, 0.25f });
    found = probe.view().cast(
        pose_a: probe_pose,
        other: surface.view(),
        pose_b: pose,
        translation_a: common - mesh_move,
        translation_b: common,
    )!!;
    assert(near(found.time, rising_time, LOOSE));
    assert(near_vector(found.point, stop_witness + common * rising_time, LOOSE));
    assert(near_vector(found.normal, toward_mesh, LOOSE));

    assert(@catch(probe.view().cast(
        pose_a: probe_pose,
        other: surface.view(),
        pose_b: pose,
        translation_a: common,
        translation_b: common,
    )) == b3::NO_HIT);

    float band_height = RAMP_SLOPE * DROP_COLUMN + (PROBE_RADIUS - BAND_OVERLAP) / RAMP_NORMAL.y;
    maths::Transform inside_band = posed(surface_point(pose, { DROP_COLUMN, band_height, 0 }));
    found = probe.view().cast(
        pose_a: inside_band,
        other: surface.view(),
        pose_b: pose,
        translation_a: pose.rotation.rotate_vec3({ 0, -1, 0 }),
        translation_b: {},
    )!!;
    assert(found.time == 0 && found.normal == (Vec3){});
}

fn void test_mesh_sweeps_with_fixed_orientations_use_the_translational_cast() @test {
    MeshQueryFixture fixture;
    setup_mesh_queries(&fixture);
    defer teardown_mesh_queries(&fixture);

    CollisionShape surface = mesh_shape(&fixture.cache, fixture.ramp);
    defer physics::destroy_collision_shape(&surface);
    CollisionShape probe = probe_sphere(mem, &fixture.cache);
    defer physics::destroy_collision_shape(&probe);

    maths::Transform pose = surface_pose();
    float falling_time = (DROP_START_HEIGHT - drop_stop_height()) / DROP_DISTANCE;
    collide::Sweep falling = {
        .start = posed(surface_point(pose, { DROP_COLUMN, DROP_START_HEIGHT, 0 })),
        .end = posed(surface_point(pose, { DROP_COLUMN, DROP_START_HEIGHT - DROP_DISTANCE, 0 })),
    };
    collide::Sweep resting = { .start = pose, .end = pose };

    collide::Impact found = surface.view().time_of_impact(
        sweep_a: resting,
        other: probe.view(),
        sweep_b: falling,
    )!!;
    assert(near(found.time, falling_time, LOOSE));
    assert(near_vector(found.normal, pose.rotation.rotate_vec3(RAMP_NORMAL), LOOSE));

    resting.end.rotation.v = -pose.rotation.v;
    found = surface.view().time_of_impact(
        sweep_a: resting,
        other: probe.view(),
        sweep_b: falling,
    )!!;
    assert(near(found.time, falling_time, LOOSE));

    resting.end.rotation = posed({}).rotation;
    assert(@catch(surface.view().time_of_impact(
        sweep_a: resting,
        other: probe.view(),
        sweep_b: falling,
    )) == c3d::UNSUPPORTED);
}

fn void test_mesh_rays_hit_front_faces_only() @test {
    MeshQueryFixture fixture;
    setup_mesh_queries(&fixture);
    defer teardown_mesh_queries(&fixture);

    CollisionShape surface = mesh_shape(&fixture.cache, fixture.ramp);
    defer physics::destroy_collision_shape(&surface);
    CollisionShape mirrored = mesh_shape(&fixture.cache, fixture.ramp, { -1, 1, 1 });
    defer physics::destroy_collision_shape(&mirrored);

    maths::Transform pose = surface_pose();
    float height = RAMP_SLOPE * RAY_COLUMN;
    Vec3 down = pose.rotation.rotate_vec3({ 0, -1, 0 });
    collide::ShapeRayHit found = surface.view().ray_cast(
        pose: pose,
        origin: surface_point(pose, { RAY_COLUMN, height + RAY_DROP, 0 }),
        direction: down,
        max_distance: RAY_LENGTH,
    )!!;
    assert(near(found.fraction, RAY_DROP / RAY_LENGTH, LOOSE));
    assert(near_vector(found.point, surface_point(pose, { RAY_COLUMN, height, 0 }), LOOSE));
    assert(near_vector(found.normal, pose.rotation.rotate_vec3(RAMP_NORMAL), LOOSE));

    assert(@catch(surface.view().ray_cast(
        pose: pose,
        origin: surface_point(pose, { RAY_COLUMN, height - RAY_DROP, 0 }),
        direction: -down,
        max_distance: RAY_LENGTH,
    )) == b3::NO_HIT);

    maths::Transform upright = posed({});
    assert(@catch(surface.view().ray_cast(
        pose: upright,
        origin: { RAY_COLUMN, height, 0 },
        direction: { 0, -1, 0 },
        max_distance: RAY_LENGTH,
    )) == b3::NO_HIT);

    found = mirrored.view().ray_cast(
        pose: upright,
        origin: { -RAY_COLUMN, height + RAY_DROP, 0 },
        direction: { 0, -1, 0 },
        max_distance: RAY_LENGTH,
    )!!;
    assert(near(found.fraction, RAY_DROP / RAY_LENGTH, LOOSE));
    assert(near_vector(found.normal, { -RAMP_NORMAL.x, RAMP_NORMAL.y, RAMP_NORMAL.z }, LOOSE));

    assert(@catch(mirrored.view().ray_cast(
        pose: upright,
        origin: { -RAY_COLUMN, height - RAY_DROP, 0 },
        direction: { 0, 1, 0 },
        max_distance: RAY_LENGTH,
    )) == b3::NO_HIT);
}

fn void test_mesh_contacts_report_exact_capacity() @test {
    MeshQueryFixture fixture;
    setup_mesh_queries(&fixture);
    defer teardown_mesh_queries(&fixture);

    CollisionShape surface = mesh_shape(&fixture.cache, fixture.fold);
    defer physics::destroy_collision_shape(&surface);
    CollisionShape prism = prism_shape(&fixture.cache, fixture.prism);
    defer physics::destroy_collision_shape(&prism);

    maths::Transform pose = surface_pose();
    maths::Transform on_flat = posed(surface_point(pose, { -1, 0, 1 }), pose.rotation);
    maths::Transform apart = posed(surface_point(pose, { -1, 5, 1 }), pose.rotation);
    CollisionContact[HEXAGON_SIDES] contacts;

    assert(surface.view().contacts(
        pose_a: pose,
        other: prism.view(),
        pose_b: on_flat,
        output: contacts[..],
    )!! == HEXAGON_SIDES);
    assert(@catch(surface.view().contacts(
        pose_a: pose,
        other: prism.view(),
        pose_b: on_flat,
        output: contacts[:HEXAGON_SIDES - 1],
    )) == c3d::CAPACITY_EXCEEDED);
    assert(@catch(surface.view().contacts(
        pose_a: pose,
        other: prism.view(),
        pose_b: on_flat,
        output: {},
    )) == c3d::CAPACITY_EXCEEDED);
    assert(surface.view().contacts(
        pose_a: pose,
        other: prism.view(),
        pose_b: apart,
        output: {},
    )!! == 0);
    assert(surface.view().contacts(
        pose_a: pose,
        other: prism.view(),
        pose_b: on_flat,
        output: contacts[..],
    )!! == HEXAGON_SIDES);
}

fn void test_mesh_queries_allocate_nothing() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    MeshQueryFixture fixture;
    setup_mesh_queries(&fixture, &tracker);
    CollisionShape surface = mesh_shape(&fixture.cache, fixture.ramp, allocator: &tracker);
    CollisionShape probe = probe_sphere(&tracker, &fixture.cache);

    maths::Transform pose = surface_pose();
    float height = RAMP_SLOPE * RAY_COLUMN;
    maths::Transform touching = posed(surface_point(pose, { RAY_COLUMN, height + PROBE_RADIUS - BAND_OVERLAP, 0 }));
    maths::Transform above = posed(surface_point(pose, { RAY_COLUMN, height + RAY_DROP, 0 }));
    Vec3 down = pose.rotation.rotate_vec3({ 0, -1, 0 });
    CollisionContact[collide::MAX_MANIFOLD_POINTS] contacts;
    sz allocations = tracker.total_allocation_count();

    assert(surface.view().contacts(
        pose_a: pose,
        other: probe.view(),
        pose_b: touching,
        output: contacts[..],
    )!! > 0);
    assert(probe.view().distance(above, surface.view(), pose)!!.distance > 0);
    assert(probe.view().cast(
        pose_a: above,
        other: surface.view(),
        pose_b: pose,
        translation_a: down * RAY_LENGTH,
        translation_b: {},
    )!!.time > 0);
    assert(surface.view().ray_cast(
        pose: pose,
        origin: above.position,
        direction: down,
        max_distance: RAY_LENGTH,
    )!!.fraction > 0);
    assert(tracker.total_allocation_count() == allocations);

    physics::destroy_collision_shape(&probe);
    physics::destroy_collision_shape(&surface);
    teardown_mesh_queries(&fixture);
    assert(!tracker.has_leaks());
}

fn void test_mesh_preparation_and_queries_refuse_unsupported_inputs() @test {
    MeshQueryFixture fixture;
    setup_mesh_queries(&fixture);
    defer teardown_mesh_queries(&fixture);

    CollisionShape first = mesh_shape(&fixture.cache, fixture.ramp);
    defer physics::destroy_collision_shape(&first);
    CollisionShape second = mesh_shape(&fixture.cache, fixture.plane);
    defer physics::destroy_collision_shape(&second);

    maths::Transform pose = surface_pose();
    CollisionContact[collide::MAX_MANIFOLD_POINTS] contacts;
    assert(@catch(first.view().contacts(pose, second.view(), pose, contacts[..])) == c3d::UNSUPPORTED);
    assert(@catch(first.view().distance(pose, second.view(), pose)) == c3d::UNSUPPORTED);
    assert(@catch(first.view().cast(
        pose_a: pose,
        other: second.view(),
        pose_b: pose,
        translation_a: {},
        translation_b: {},
    )) == c3d::UNSUPPORTED);
    assert(@catch(first.view().time_of_impact(
        sweep_a: { .start = pose, .end = pose },
        other: second.view(),
        sweep_b: { .start = pose, .end = pose },
    )) == c3d::UNSUPPORTED);

    float below_minimum = bitcast(bitcast(0.01f, uint) - 1, float);
    CollisionShapeDesc desc = scaled_shape_desc(MESH, { 1, -0.01f, 1 });
    desc.geometry = fixture.ramp;
    CollisionShape thin = physics::create_collision_shape(mem, &fixture.cache, desc)!!;
    physics::destroy_collision_shape(&thin);

    desc.scale = { 1, -below_minimum, 1 };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::UNSUPPORTED);

    GeometryId tiny = add_mesh_geometry(
        &fixture.assets,
        (Vec3[3]){ {}, { TINY_TRIANGLE_SIDE, 0, 0 }, { 0, TINY_TRIANGLE_SIDE, 0 } }[..],
        (uint[3]){ 0, 1, 2 }[..],
    );
    desc = scaled_shape_desc(MESH, { 1, 1, 1 });
    desc.geometry = tiny;
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == b3::DEGENERATE_GEOMETRY);

    Vec3[3] corners = { {}, { 1, 0, 0 }, { 0, 1, 0 } };
    uint[3] winding = { 0, 1, 2 };
    desc.geometry = add_mesh_geometry(&fixture.assets, corners[..], winding[..]);
    desc.material_indices = (char[2]){ 0, 0 }[..];
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::INVALID_ARGUMENT);

    corners[1].x = float::nan;
    desc.geometry = add_mesh_geometry(&fixture.assets, corners[..], winding[..]);
    desc.material_indices = {};
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::INVALID_ARGUMENT);

    corners[1].x = 1;
    winding[2] = 3;
    desc.geometry = add_mesh_geometry(&fixture.assets, corners[..], winding[..]);
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::INVALID_ARGUMENT);

    CollisionShape probe = probe_sphere(mem, &fixture.cache);
    defer physics::destroy_collision_shape(&probe);
    maths::Transform turned = pose;
    turned.rotation = posed({}).rotation;
    assert(@catch(first.view().time_of_impact(
        sweep_a: { .start = pose, .end = pose },
        other: probe.view(),
        sweep_b: { .start = pose, .end = turned },
    )) == c3d::UNSUPPORTED);
    assert(fixture.cache.state.borrowers == 3);
}
