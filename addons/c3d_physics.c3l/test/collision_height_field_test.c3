module c3d_physics_collide_test;

import c3d;
import c3d::material;
import std::math;
import std::math::quaternion;
import b3;

const uint FIELD_COLUMNS @private = 5; // grid points along x
const uint FIELD_ROWS @private = 4; // grid points along z
const float FIELD_RISE @private = 0.4f; // raw height gained per column
const Vec3 FIELD_SCALE @private = { 2, 1.5f, 1 };
const float FIELD_SLOPE @private = FIELD_RISE * FIELD_SCALE.y / FIELD_SCALE.x; // the surface is the plane y = SLOPE * x
const float FIELD_END_X @private = FIELD_SCALE.x * (FIELD_COLUMNS - 1);
const uint HOLE_COLUMN @private = 2;
const uint HOLE_ROW @private = 1;
const float TRIANGLE_INRADIUS @private = 0.381966f; // of the right triangle with legs 2 and 1 that opens each cell: (2 + 1 - sqrt(5)) / 2
const float DEPTH @private = 0.1f;
const float HOVER @private = 0.6f; // probe centre height above the plane when it hangs over the hole
const float HOLE_PROBE_RADIUS @private = 0.2f; // narrower than the hole, so it can fall through
const float BOX_HALF_HEIGHT @private = 0.05f;
const float BOX_HALF_SIDE @private = 0.2f; // the footprint fits inside the incircle of one triangle
const float RAY_HEIGHT @private = 2;
const float SLOPE_RAY_LENGTH @private = 6;
const float DROP_HEIGHT @private = 3;
const float SLOPE_DROP_DISTANCE @private = 4;
const float SLOPE_BAND_OVERLAP @private = 0.01f; // starting overlap that puts a cast inside the native closing band
const float NATIVE_HEIGHT_LEVELS @private = 65535; // box3d quantizes each height to 16 bits
const float NATIVE_MINIMUM_RANGE @private = 0.005f; // box3d widens a flatter range to its linear slop
const Vec3 STEEP_SCALE @private = { 2, 1000, 3 };
const float STEEP_RANGE @private = 1; // raw range of the quantization fixture
const float NARROW_SPACING @private = 1e-12f; // finite reciprocal, but a unit extent spans more cells than an int holds
const float DEGENERATE_SPACING @private = 1e-12f; // cells with an area far below the native triangle floor
const float WIDE_SPACING @private = 1000;
const float FAR_DISTANCE @private = 1e30f;
const uint OVERFLOW_COLUMNS @private = 65536; // the point count alone exceeds a signed int
const uint LARGE_COLUMNS @private = 32768; // the point count fits, the blob offsets do not

struct FieldQueryFixture @private {
    AssetStore assets;
    CollisionCache cache;
    float[FIELD_COLUMNS * FIELD_ROWS] heights;
    char[(FIELD_COLUMNS - 1) * (FIELD_ROWS - 1)] materials;
}

fn void setup_field_queries(FieldQueryFixture* fixture, Allocator allocator = mem) @private {
    fixture.assets = asset::create_asset_store(allocator, asset::default_asset_store_desc());
    fixture.cache = physics::create_collision_cache(
        allocator: allocator,
        assets: &fixture.assets,
        desc: physics::default_collision_cache_desc(),
    )!!;

    for (uint row = 0; row < FIELD_ROWS; row++) {
        for (uint column = 0; column < FIELD_COLUMNS; column++) {
            fixture.heights[row * FIELD_COLUMNS + column] = (float)column * FIELD_RISE;
        }
    }
    fixture.materials[HOLE_ROW * (FIELD_COLUMNS - 1) + HOLE_COLUMN] = physics::HEIGHT_FIELD_HOLE;
}

fn void teardown_field_queries(FieldQueryFixture* fixture) @private {
    physics::destroy_collision_cache(&fixture.cache)!!;
    asset::destroy_asset_store(&fixture.assets);
}

fn CollisionShape field_shape(
    CollisionCache* cache,
    float[] heights,
    uint columns,
    uint rows,
    Vec3 scale,
    char[] materials = {},
    Allocator allocator = mem,
) @private {
    CollisionShapeDesc desc = scaled_shape_desc(HEIGHT_FIELD, scale);
    desc.height_field = { .heights = heights, .count_x = columns, .count_z = rows };
    desc.material_indices = materials;

    return physics::create_collision_shape(allocator, cache, desc)!!;
}

fn CollisionShape slope_shape(FieldQueryFixture* fixture, Allocator allocator = mem) @private {
    return field_shape(
        cache: &fixture.cache,
        heights: fixture.heights[..],
        columns: FIELD_COLUMNS,
        rows: FIELD_ROWS,
        scale: FIELD_SCALE,
        materials: fixture.materials[..],
        allocator: allocator,
    );
}

fn CollisionShape radius_sphere(CollisionCache* cache, float radius, Allocator allocator = mem) @private {
    CollisionShapeDesc desc = scaled_shape_desc(SPHERE, { 1, 1, 1 });
    desc.radius = radius;

    return physics::create_collision_shape(allocator, cache, desc)!!;
}

fn CollisionShape tilted_box_shape(CollisionCache* cache) @private {
    CollisionShapeDesc desc = scaled_shape_desc(BOX, { 1, 1, 1 });
    desc.half_extents = { BOX_HALF_SIDE, BOX_HALF_HEIGHT, BOX_HALF_SIDE };

    return physics::create_collision_shape(mem, cache, desc)!!;
}

fn maths::Transform field_pose() @private => posed({ 3, -2, 4 }, rotated());

fn Vec3 field_point(maths::Transform pose, Vec3 local) @private => pose.position + pose.rotation.rotate_vec3(local);

fn Vec3 field_normal() @private => ((Vec3){ -FIELD_SLOPE, 1, 0 }).normalize();

fn Vec3 slope_point(float x, float z) @private => { x, FIELD_SLOPE * x, z };

fn Vec3 incenter_point() @private => slope_point(FIELD_SCALE.x + TRIANGLE_INRADIUS, TRIANGLE_INRADIUS);

fn Vec3 hole_centre() @private {
    return slope_point(FIELD_SCALE.x * (HOLE_COLUMN + 0.5f), FIELD_SCALE.z * (HOLE_ROW + 0.5f));
}

fn float slope_stop_height(float x, float radius) @private {
    return FIELD_SLOPE * x + (radius - LINEAR_SLOP) / field_normal().y;
}

fn void test_height_field_contacts_press_shapes_into_the_slope_and_skip_the_hole() @test {
    FieldQueryFixture fixture;
    setup_field_queries(&fixture);
    defer teardown_field_queries(&fixture);

    CollisionShape surface = slope_shape(&fixture);
    defer physics::destroy_collision_shape(&surface);
    CollisionShape probe = radius_sphere(&fixture.cache, PROBE_RADIUS);
    defer physics::destroy_collision_shape(&probe);
    CollisionShape box = tilted_box_shape(&fixture.cache);
    defer physics::destroy_collision_shape(&box);

    maths::Transform pose = field_pose();
    Vec3 normal = field_normal();
    Vec3 up = pose.rotation.rotate_vec3(normal);
    Vec3 foot = incenter_point();
    CollisionContact[collide::MAX_MANIFOLD_POINTS] contacts;

    maths::Transform pressed = posed(field_point(pose, foot + normal * (PROBE_RADIUS - DEPTH)));
    usz count = surface.view().contacts(
        pose_a: pose,
        other: probe.view(),
        pose_b: pressed,
        output: contacts[..],
    )!!;
    assert(count == 1);
    assert(near(contacts[0].separation, -DEPTH, LOOSE));
    assert(near_vector(contacts[0].normal, up, LOOSE));
    assert(near_vector(contacts[0].point, field_point(pose, foot - normal * (DEPTH / 2)), LOOSE));
    assert(contacts[0].triangle_index == 2); // the first triangle of the cell in column 1, row 0

    count = probe.view().contacts(
        pose_a: pressed,
        other: surface.view(),
        pose_b: pose,
        output: contacts[..],
    )!!;
    assert(count == 1);
    assert(near(contacts[0].separation, -DEPTH, LOOSE));
    assert(near_vector(contacts[0].normal, -up, LOOSE));
    assert(near_vector(contacts[0].point, field_point(pose, foot - normal * (DEPTH / 2)), LOOSE));

    float box_depth = BOX_HALF_HEIGHT / 2;
    Quat tilt = quaternion::from_axis_angle{float}({ 0, 0, 1 }, math::atan(FIELD_SLOPE));
    maths::Transform lying = posed(
        field_point(pose, foot + normal * (BOX_HALF_HEIGHT - box_depth)),
        pose.rotation.mul(tilt),
    );
    count = surface.view().contacts(
        pose_a: pose,
        other: box.view(),
        pose_b: lying,
        output: contacts[..],
    )!!;
    assert(count == 4);
    foreach (contact : contacts[:count]) {
        assert(near(contact.separation, -box_depth, LOOSE));
        assert(near_vector(contact.normal, up, LOOSE));
    }

    Vec3 over_hole = hole_centre();
    maths::Transform hanging = posed(field_point(pose, over_hole + normal * (PROBE_RADIUS - DEPTH)));
    assert(surface.view().contacts(
        pose_a: pose,
        other: probe.view(),
        pose_b: hanging,
        output: contacts[..],
    )!! == 0);
}

fn void test_height_field_distance_is_the_global_minimum_over_the_retained_cells() @test {
    FieldQueryFixture fixture;
    setup_field_queries(&fixture);
    defer teardown_field_queries(&fixture);

    CollisionShape surface = slope_shape(&fixture);
    defer physics::destroy_collision_shape(&surface);
    CollisionShape probe = radius_sphere(&fixture.cache, PROBE_RADIUS);
    defer physics::destroy_collision_shape(&probe);

    maths::Transform pose = field_pose();
    float beyond = 4;
    float crest = FIELD_SLOPE * FIELD_END_X;
    float strip = 0.5f;
    maths::Transform past_the_edge = posed(field_point(pose, { FIELD_END_X + beyond, crest, strip }));
    collide::Distance found = probe.view().distance(
        pose_a: past_the_edge,
        other: surface.view(),
        pose_b: pose,
    )!!;
    assert(near(found.distance, beyond - PROBE_RADIUS, LOOSE));
    assert(near_vector(found.point_a, field_point(pose, { FIELD_END_X + beyond - PROBE_RADIUS, crest, strip }), LOOSE));
    assert(near_vector(found.point_b, field_point(pose, { FIELD_END_X, crest, strip }), LOOSE));
    assert(near_vector(found.normal, pose.rotation.rotate_vec3({ -1, 0, 0 }), LOOSE));

    Vec3 normal = field_normal();
    float offset = 0.4f; // in-plane distance from the probe to the hole's nearest edge
    Vec3 beside_edge = slope_point(hole_centre().x, FIELD_SCALE.z * HOLE_ROW + offset);
    Vec3 edge = slope_point(beside_edge.x, FIELD_SCALE.z * HOLE_ROW);
    Vec3 hanging = beside_edge + normal * HOVER;
    float edge_distance = (hanging - edge).length();
    found = probe.view().distance(
        pose_a: posed(field_point(pose, hanging)),
        other: surface.view(),
        pose_b: pose,
    )!!;
    assert(near(found.distance, edge_distance - PROBE_RADIUS, LOOSE));
    assert(near_vector(found.point_b, field_point(pose, edge), LOOSE));
    assert(near_vector(found.normal, pose.rotation.rotate_vec3((edge - hanging).normalize()), LOOSE));
    assert(HOVER - PROBE_RADIUS < found.distance - LOOSE); // a plane through the hole would be nearer

    maths::Transform pressed = posed(field_point(pose, incenter_point() + normal * (PROBE_RADIUS - DEPTH)));
    found = probe.view().distance(
        pose_a: pressed,
        other: surface.view(),
        pose_b: pose,
    )!!;
    assert(found.distance == 0);
}

fn void test_height_field_casts_close_on_the_slope_with_either_side_moving() @test {
    FieldQueryFixture fixture;
    setup_field_queries(&fixture);
    defer teardown_field_queries(&fixture);

    CollisionShape surface = slope_shape(&fixture);
    defer physics::destroy_collision_shape(&surface);
    CollisionShape probe = radius_sphere(&fixture.cache, PROBE_RADIUS);
    defer physics::destroy_collision_shape(&probe);
    CollisionShape needle = radius_sphere(&fixture.cache, HOLE_PROBE_RADIUS);
    defer physics::destroy_collision_shape(&needle);

    maths::Transform pose = field_pose();
    Vec3 normal = field_normal();
    Vec3 foot = incenter_point();
    float stop_height = slope_stop_height(foot.x, PROBE_RADIUS);
    float start_height = stop_height + DROP_HEIGHT;
    float closing = PROBE_RADIUS - LINEAR_SLOP;
    Vec3 stop_centre = { foot.x, stop_height, foot.z };
    Vec3 stop_witness = field_point(pose, stop_centre - normal * closing);
    Vec3 toward_field = -pose.rotation.rotate_vec3(normal);
    maths::Transform above = posed(field_point(pose, { foot.x, start_height, foot.z }));

    collide::Impact found = probe.view().cast(
        pose_a: above,
        other: surface.view(),
        pose_b: pose,
        translation_a: pose.rotation.rotate_vec3({ 0, -SLOPE_DROP_DISTANCE, 0 }),
        translation_b: {},
    )!!;
    assert(near(found.time, DROP_HEIGHT / SLOPE_DROP_DISTANCE, LOOSE));
    assert(near_vector(found.point, stop_witness, LOOSE));
    assert(near_vector(found.normal, toward_field, LOOSE));

    float rising = SLOPE_DROP_DISTANCE;
    Vec3 field_move = pose.rotation.rotate_vec3({ 0, rising, 0 });
    found = probe.view().cast(
        pose_a: above,
        other: surface.view(),
        pose_b: pose,
        translation_a: {},
        translation_b: field_move,
    )!!;
    assert(near(found.time, DROP_HEIGHT / rising, LOOSE));
    assert(near_vector(found.point, stop_witness + field_move * found.time, LOOSE));
    assert(near_vector(found.normal, toward_field, LOOSE));

    Vec3 over_hole = hole_centre();
    maths::Transform falling = posed(field_point(pose, over_hole + (Vec3){ 0, DROP_HEIGHT, 0 }));
    assert(@catch(needle.view().cast(
        pose_a: falling,
        other: surface.view(),
        pose_b: pose,
        translation_a: pose.rotation.rotate_vec3({ 0, -2 * DROP_HEIGHT, 0 }),
        translation_b: {},
    )) == b3::NO_HIT);

    float band_height = FIELD_SLOPE * foot.x + (PROBE_RADIUS - SLOPE_BAND_OVERLAP) / normal.y;
    maths::Transform inside_band = posed(field_point(pose, { foot.x, band_height, foot.z }));
    found = probe.view().cast(
        pose_a: inside_band,
        other: surface.view(),
        pose_b: pose,
        translation_a: pose.rotation.rotate_vec3({ 0, -1, 0 }),
        translation_b: {},
    )!!;
    assert(found.time == 0 && found.normal == (Vec3){});
}

fn void test_height_field_rays_hit_front_faces_and_pass_through_holes() @test {
    FieldQueryFixture fixture;
    setup_field_queries(&fixture);
    defer teardown_field_queries(&fixture);

    CollisionShape surface = slope_shape(&fixture);
    defer physics::destroy_collision_shape(&surface);

    maths::Transform pose = field_pose();
    Vec3 down = pose.rotation.rotate_vec3({ 0, -1, 0 });
    Vec3 target = slope_point(2.5f, 0.25f);
    collide::ShapeRayHit found = surface.view().ray_cast(
        pose: pose,
        origin: field_point(pose, target + (Vec3){ 0, RAY_HEIGHT, 0 }),
        direction: down,
        max_distance: SLOPE_RAY_LENGTH,
    )!!;
    assert(near(found.fraction, RAY_HEIGHT / SLOPE_RAY_LENGTH, LOOSE));
    assert(near_vector(found.point, field_point(pose, target), LOOSE));
    assert(near_vector(found.normal, pose.rotation.rotate_vec3(field_normal()), LOOSE));

    Vec3 over_hole = hole_centre();
    assert(@catch(surface.view().ray_cast(
        pose: pose,
        origin: field_point(pose, over_hole + (Vec3){ 0, RAY_HEIGHT, 0 }),
        direction: down,
        max_distance: SLOPE_RAY_LENGTH,
    )) == b3::NO_HIT);

    assert(@catch(surface.view().ray_cast(
        pose: pose,
        origin: field_point(pose, target - (Vec3){ 0, RAY_HEIGHT, 0 }),
        direction: -down,
        max_distance: SLOPE_RAY_LENGTH,
    )) == b3::NO_HIT);
}

fn void test_height_field_of_only_holes_has_no_surface() @test {
    FieldQueryFixture fixture;
    setup_field_queries(&fixture);
    defer teardown_field_queries(&fixture);

    float[9] flat;
    char[4] holes;
    foreach (&hole : holes) *hole = physics::HEIGHT_FIELD_HOLE;
    CollisionShape surface = field_shape(
        cache: &fixture.cache,
        heights: flat[..],
        columns: 3,
        rows: 3,
        scale: { 1, 1, 1 },
        materials: holes[..],
    );
    defer physics::destroy_collision_shape(&surface);
    CollisionShape probe = radius_sphere(&fixture.cache, PROBE_RADIUS);
    defer physics::destroy_collision_shape(&probe);

    maths::Transform pose = field_pose();
    maths::Transform touching = posed(field_point(pose, { 1, PROBE_RADIUS - DEPTH, 1 }));
    assert(surface.view().contacts(
        pose_a: pose,
        other: probe.view(),
        pose_b: touching,
        output: {},
    )!! == 0);
    assert(@catch(probe.view().distance(touching, surface.view(), pose)) == b3::NO_HIT);

    Vec3 down = pose.rotation.rotate_vec3({ 0, -1, 0 });
    assert(@catch(probe.view().cast(
        pose_a: touching,
        other: surface.view(),
        pose_b: pose,
        translation_a: down,
        translation_b: {},
    )) == b3::NO_HIT);
    assert(@catch(surface.view().ray_cast(
        pose: pose,
        origin: field_point(pose, { 1, RAY_HEIGHT, 1 }),
        direction: down,
        max_distance: SLOPE_RAY_LENGTH,
    )) == b3::NO_HIT);
}

fn void test_scaled_height_field_stays_within_one_height_step_of_the_analytic_surface() @test {
    FieldQueryFixture fixture;
    setup_field_queries(&fixture);
    defer teardown_field_queries(&fixture);

    float[6] samples = { 0, 0.4f, STEEP_RANGE, 0, 0.4f, STEEP_RANGE };
    CollisionShape surface = field_shape(
        cache: &fixture.cache,
        heights: samples[..],
        columns: 3,
        rows: 2,
        scale: STEEP_SCALE,
    );
    defer physics::destroy_collision_shape(&surface);

    float step = math::max(STEEP_RANGE, NATIVE_MINIMUM_RANGE) / NATIVE_HEIGHT_LEVELS * STEEP_SCALE.y;
    float analytic = STEEP_SCALE.y * (0.4f + STEEP_RANGE) / 2; // midway along the second cell
    collide::ShapeRayHit found = surface.view().ray_cast(
        pose: posed({}),
        origin: { STEEP_SCALE.x * 1.5f, 2 * analytic, STEEP_SCALE.z / 4 },
        direction: { 0, -1, 0 },
        max_distance: 4 * analytic,
    )!!;
    assert(math::abs(found.point.y - analytic) <= step + LOOSE);
    assert(near(found.point.x, STEEP_SCALE.x * 1.5f, LOOSE));
}

fn void test_height_field_contacts_report_exact_capacity() @test {
    FieldQueryFixture fixture;
    setup_field_queries(&fixture);
    defer teardown_field_queries(&fixture);

    CollisionShape surface = slope_shape(&fixture);
    defer physics::destroy_collision_shape(&surface);
    CollisionShape box = tilted_box_shape(&fixture.cache);
    defer physics::destroy_collision_shape(&box);

    maths::Transform pose = field_pose();
    Vec3 normal = field_normal();
    Vec3 foot = incenter_point();
    Quat tilt = quaternion::from_axis_angle{float}({ 0, 0, 1 }, math::atan(FIELD_SLOPE));
    maths::Transform lying = posed(
        field_point(pose, foot + normal * (BOX_HALF_HEIGHT / 2)),
        pose.rotation.mul(tilt),
    );
    maths::Transform apart = posed(
        field_point(pose, foot + normal * DROP_HEIGHT),
        pose.rotation.mul(tilt),
    );
    usz expected = 4;
    CollisionContact[4] contacts;

    assert(surface.view().contacts(
        pose_a: pose,
        other: box.view(),
        pose_b: lying,
        output: contacts[..],
    )!! == expected);
    assert(@catch(surface.view().contacts(
        pose_a: pose,
        other: box.view(),
        pose_b: lying,
        output: contacts[:expected - 1],
    )) == c3d::CAPACITY_EXCEEDED);
    assert(@catch(surface.view().contacts(
        pose_a: pose,
        other: box.view(),
        pose_b: lying,
        output: {},
    )) == c3d::CAPACITY_EXCEEDED);
    assert(surface.view().contacts(
        pose_a: pose,
        other: box.view(),
        pose_b: apart,
        output: {},
    )!! == 0);
    assert(surface.view().contacts(
        pose_a: pose,
        other: box.view(),
        pose_b: lying,
        output: contacts[..],
    )!! == expected);
}

fn void test_height_field_queries_allocate_nothing() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    FieldQueryFixture fixture;
    setup_field_queries(&fixture, &tracker);
    CollisionShape surface = slope_shape(&fixture, &tracker);
    CollisionShape probe = radius_sphere(&fixture.cache, PROBE_RADIUS, &tracker);

    maths::Transform pose = field_pose();
    Vec3 normal = field_normal();
    Vec3 foot = incenter_point();
    maths::Transform touching = posed(field_point(pose, foot + normal * (PROBE_RADIUS - DEPTH)));
    maths::Transform above = posed(field_point(pose, foot + (Vec3){ 0, DROP_HEIGHT, 0 }));
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
        translation_a: down * SLOPE_DROP_DISTANCE,
        translation_b: {},
    )!!.time > 0);
    assert(surface.view().ray_cast(
        pose: pose,
        origin: above.position,
        direction: down,
        max_distance: SLOPE_RAY_LENGTH,
    )!!.fraction > 0);
    assert(tracker.total_allocation_count() == allocations);

    physics::destroy_collision_shape(&probe);
    physics::destroy_collision_shape(&surface);
    teardown_field_queries(&fixture);
    assert(!tracker.has_leaks());
}

fn void test_height_field_preparation_and_queries_refuse_unsupported_inputs() @test {
    FieldQueryFixture fixture;
    setup_field_queries(&fixture);
    defer teardown_field_queries(&fixture);

    float[4] flat;
    CollisionShapeDesc desc = scaled_shape_desc(HEIGHT_FIELD, { 1, 1, 1 });
    desc.height_field = { .heights = flat[..], .count_x = 2, .count_z = 2 };
    CollisionShape accepted = physics::create_collision_shape(mem, &fixture.cache, desc)!!;
    physics::destroy_collision_shape(&accepted);

    desc.scale = { -1, 1, 1 };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::UNSUPPORTED);
    desc.scale = { 1, 1, -1 };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::UNSUPPORTED);
    desc.scale = { 0, 1, 1 };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::INVALID_ARGUMENT);
    desc.scale = { 1, float::nan, 1 };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::INVALID_ARGUMENT);
    desc.scale = { 1e-39f, 1, 1 };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == b3::DEGENERATE_GEOMETRY);
    desc.scale = { DEGENERATE_SPACING, 1, DEGENERATE_SPACING };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == b3::DEGENERATE_GEOMETRY);
    desc.scale = { 1, 1, 1 };

    desc.height_field.count_x = 1;
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::INVALID_ARGUMENT);
    desc.height_field.count_x = 3;
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::INVALID_ARGUMENT);
    desc.height_field.count_x = 2;
    char[2] mismatched;
    desc.material_indices = mismatched[..];
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::INVALID_ARGUMENT);
    desc.material_indices = {};

    float[4] broken = { 0, 0, 0, 0 };
    desc.height_field.heights = broken[..];
    foreach (value : (float[2]){ float::nan, float::inf }) {
        broken[3] = value;
        assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::INVALID_ARGUMENT);
    }
    broken = { -float::max, 0, 0, float::max };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == b3::DEGENERATE_GEOMETRY);

    desc = scaled_shape_desc(HEIGHT_FIELD, { 1, 1, 1 });
    desc.height_field = { .count_x = OVERFLOW_COLUMNS, .count_z = OVERFLOW_COLUMNS };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::CAPACITY_EXCEEDED);
    desc.height_field = { .count_x = LARGE_COLUMNS, .count_z = LARGE_COLUMNS };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::CAPACITY_EXCEEDED);

    desc.height_field = { .source = TEXTURE };
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::INVALID_ID);
    ushort[4] texels;
    desc.height_field.texture = add_field_texture(&fixture.assets, texels[..], 2, 2);
    desc.material_indices = mismatched[..];
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::INVALID_ARGUMENT);
    desc.material_indices = {};
    material::TextureDesc unreadable = material::texture_2d_desc(2, 2, RGBA8_SRGB);
    unreadable.generate_mips = false;
    char[16] pixels;
    desc.height_field.texture = fixture.assets.add_texture(unreadable, pixels[..])!!;
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::UNSUPPORTED);
    desc = physics::default_collision_shape_desc(physics::ColliderKind.COMPOUND);
    assert(@catch(physics::create_collision_shape(mem, &fixture.cache, desc)) == c3d::UNSUPPORTED);
    assert(fixture.cache.state.borrowers == 0);

    CollisionShape first = slope_shape(&fixture);
    defer physics::destroy_collision_shape(&first);
    CollisionShape second = slope_shape(&fixture);
    defer physics::destroy_collision_shape(&second);
    CollisionShape triangle = mesh_shape(&fixture.cache, add_plane_triangle(&fixture.assets));
    defer physics::destroy_collision_shape(&triangle);

    maths::Transform pose = field_pose();
    CollisionContact[collide::MAX_MANIFOLD_POINTS] contacts;
    foreach (other : (CollisionShapeView[2]){ second.view(), triangle.view() }) {
        assert(@catch(first.view().contacts(
            pose_a: pose,
            other: other,
            pose_b: pose,
            output: contacts[..],
        )) == c3d::UNSUPPORTED);
        assert(@catch(first.view().distance(pose, other, pose)) == c3d::UNSUPPORTED);
        assert(@catch(first.view().cast(
            pose_a: pose,
            other: other,
            pose_b: pose,
            translation_a: {},
            translation_b: {},
        )) == c3d::UNSUPPORTED);
        assert(@catch(first.view().time_of_impact(
            sweep_a: { .start = pose, .end = pose },
            other: other,
            sweep_b: { .start = pose, .end = pose },
        )) == c3d::UNSUPPORTED);
    }

    CollisionShape probe = radius_sphere(&fixture.cache, PROBE_RADIUS);
    defer physics::destroy_collision_shape(&probe);
    maths::Transform remote = posed({ FAR_DISTANCE, 0, 0 });
    assert(@catch(first.view().contacts(
        pose_a: pose,
        other: probe.view(),
        pose_b: remote,
        output: contacts[..],
    )) == c3d::UNSUPPORTED);

    float[9] strip;
    CollisionShape narrow = field_shape(
        cache: &fixture.cache,
        heights: strip[..],
        columns: 3,
        rows: 3,
        scale: { NARROW_SPACING, 1, WIDE_SPACING },
    );
    defer physics::destroy_collision_shape(&narrow);
    Vec3 above_the_strip = { 0, 2, WIDE_SPACING };
    assert(near(probe.view().distance(posed(above_the_strip), narrow.view(), posed({}))!!.distance, 1.5f, LOOSE));
    assert(narrow.view().contacts(
        pose_a: posed({}),
        other: probe.view(),
        pose_b: posed(above_the_strip),
        output: {},
    )!! == 0);

    Vec3 near_the_field = { 0, 1, WIDE_SPACING };
    assert(@catch(probe.view().cast(
        pose_a: posed(near_the_field),
        other: narrow.view(),
        pose_b: posed({}),
        translation_a: { 0, -2, 0 },
        translation_b: {},
    )) == c3d::UNSUPPORTED);
    assert(@catch(narrow.view().ray_cast(
        pose: posed({}),
        origin: near_the_field,
        direction: { 0, -1, 0 },
        max_distance: 2,
    )) == c3d::UNSUPPORTED);
    assert(fixture.cache.state.borrowers == 5);
}
