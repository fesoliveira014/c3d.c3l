module c3d_water_test;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::landscape::water @public;
import c3d::maths;
import c3d::material;
import c3d::scene;

const float GENTLE_STEEPNESS @local = 0.3f; // 0.3^7 of a first step under 0.3 m is below the tolerance
const float STEEP_STEEPNESS @local = 0.95f; // near the validated limit of 1: the slowest contraction the test checks
const float ROUNDING_SLACK @local = 0.00002f; // metres: float spacing of 64 m positions and phases, carried through the height
const uint ERROR_GRID @local = 64; // rest points per side, one metre apart
const uint ERROR_TIMES @local = 8;
const double ERROR_TIME_STEP @local = 0.37;
const float QUERY_TOLERANCE @local = 0.0001f; // metres; float rounding of the rotated node
const float MATRIX_TOLERANCE @local = 0.00001f;
const float SCROLL_TOLERANCE @local = 0.0001f; // texture-space periods; float rounding of the segment change
const float DIFFERENCE_STEP @local = 0.015625f; // 2^-6 metres and seconds: exact in float, no rounding of its own
const float KINEMATIC_TOLERANCE @local = 0.0005f; // metres per second; measures 1.7e-4
const float NORMAL_TOLERANCE @local = 0.0002f; // length of a unit vector difference; measures 4.4e-5
const Vec2[3] DETAIL_POINTS @local = { { 1, 2 }, { -7, 4.5f }, { 9.5f, -9.5f } }; // node-local metres
const double[2] DETAIL_TIMES @local = { 2.25, 6.5 }; // seconds, exact in float
const Vec3 CURRENT @local = { 0.5f, 0, -0.25f }; // metres per second
const float SAMPLER_OFFSET @local = 0.25f; // seconds, exact in float
const Vec3 ORIGIN_SHIFT @local = { 40, 0, -24 }; // metres; moves the 20 m body well off its old position
const Vec3 WATER_POSITION @local = { 3, -2, 5 };
const float WATER_YAW_DEGREES @local = 30;
const uint WATER_LAYER @local = 1 << 3;

struct Fixture @local {
    AssetStore assets;
    Scene      scene;
    Node*      camera;
}

struct Truth @local {
    double x;
    double y;
    double z;
}

fn void setup(Fixture* fixture) @local {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(mem, scene::default_scene_desc());
    water::register_water(&fixture.scene, &fixture.assets)!!;
    fixture.camera = fixture.scene.add_camera(camera::perspective_deg(60, 0.1f))!!;
}

fn void teardown(Fixture* fixture) @local {
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn WaterDesc calm_desc() @local {
    WaterDesc desc = water::default_water_desc();
    desc.extent = 200;
    desc.cell_size = 1;
    return desc;
}

fn WaterDesc choppy_desc(float steepness) @local {
    WaterDesc desc = calm_desc();
    desc.waves = {
        { .amplitude = 0.35f, .wavelength = 12, .speed = 2.5f, .direction = { 1, 0 }, .steepness = steepness },
        { .amplitude = 0.2f, .wavelength = 7, .speed = 1.9f, .direction = { 0.8f, 0.6f }, .steepness = steepness },
        { .amplitude = 0.12f, .wavelength = 4, .speed = 1.4f, .direction = { 0.28f, 0.96f }, .steepness = steepness },
        { .amplitude = 0.06f, .wavelength = 2, .speed = 1.0f, .direction = { -0.6f, 0.8f }, .steepness = steepness },
    };
    desc.wave_count = 4;
    return desc;
}

fn void? try_add(Fixture* fixture, Node* node, WaterDesc desc) @local {
    return water::add_water(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   node,
        desc:   desc,
    );
}

fn Node* add_water_node(
    Fixture* fixture,
    WaterDesc desc,
    Vec3 position = {},
    float yaw_degrees = 0,
) @local {
    Node* node = fixture.scene.add_node()!!;
    node.local.position = position;
    node.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::deg_to_rad(yaw_degrees));
    fixture.scene.update_world();
    try_add(fixture, node, desc)!!;
    return node;
}

fn void update_water(Fixture* fixture, Vec3 wind = {}, double time = 0) @local {
    water::update(
        scene:         &fixture.scene,
        assets:        &fixture.assets,
        wind_velocity: wind,
        time:          time,
    );
}

fn void? try_update_mirror(
    Fixture* fixture,
    Entity body,
    uint slot = 0,
    Entity viewing_camera = {},
) @local {
    return water::update_mirror(
        scene:          &fixture.scene,
        body:           body,
        slot:           slot,
        viewing_camera: viewing_camera.generation ? viewing_camera : fixture.camera.id,
    );
}

fn void? try_set_desc(Fixture* fixture, Node* node, WaterDesc desc) @local {
    return water::set_desc(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   node,
        desc:   desc,
    );
}

fn void assert_fault(fault excuse, fault expected, String what) @local {
    assert(excuse, "%s was accepted.", what);
    assert(excuse == expected, "%s faulted %s.", what, excuse);
}

// The page's Gerstner surface in double precision, from the authored waves: a rest point and where it is drawn.
fn Truth displaced(
    WaterDesc* desc,
    double rest_x,
    double rest_z,
    double time,
) @local {
    Truth point = { .x = rest_x, .z = rest_z };
    foreach (&wave : desc.waves[:desc.wave_count]) {
        double wavenumber = 2 * math::PI / wave.wavelength;
        double phase = wavenumber * (wave.direction.x * rest_x + wave.direction.y * rest_z - wave.speed * time);
        double shift = wave.steepness / (wavenumber * desc.wave_count);
        point.x += shift * wave.direction.x * math::cos(phase);
        point.y += wave.amplitude * math::sin(phase);
        point.z += shift * wave.direction.y * math::cos(phase);
    }
    return point;
}

fn float? height_at(SurfaceView* view, float world_x, float world_z, double time) @local {
    return water::sample_surface(
        view:    view,
        world_x: world_x,
        world_z: world_z,
        time:    time,
    );
}

struct SurfaceSlopes @local {
    float x;
    float z;
    float time;
}

// Central differences of the public height, the reference the analytic detail is compared with.
fn SurfaceSlopes slopes_at(SurfaceView* view, Vec3 point, double time) @local {
    float step = DIFFERENCE_STEP;
    float east = height_over(view, { point.x + step, 0, point.z }, time);
    float west = height_over(view, { point.x - step, 0, point.z }, time);
    float north = height_over(view, { point.x, 0, point.z + step }, time);
    float south = height_over(view, { point.x, 0, point.z - step }, time);
    float later = height_over(view, point, time + (double)step);
    float earlier = height_over(view, point, time - (double)step);

    return {
        .x    = (east - west) / (2 * step),
        .z    = (north - south) / (2 * step),
        .time = (later - earlier) / (2 * step),
    };
}

fn float height_over(SurfaceView* view, Vec3 point, double time) @local {
    return height_at(
        view:    view,
        world_x: point.x,
        world_z: point.z,
        time:    time,
    )!!;
}

fn WaterSample detail_at(SurfaceView* view, Vec3 point, double time) @local {
    return water::sample_surface_detail(
        view:    view,
        world_x: point.x,
        world_z: point.z,
        time:    time,
    )!!;
}

struct InversionReport @local {
    float largest_residual;
    float largest_excess; // metres by which a height error passed the bound its residual gives
}

// Mean steepness bounds the Jacobian of the horizontal map, so it is the contraction factor.
fn float mean_steepness(WaterDesc* desc) @local {
    float total;
    foreach (&wave : desc.waves[:desc.wave_count]) total += wave.steepness;
    return total / desc.wave_count;
}

// Metres of height per metre of rest position, at most.
fn float height_slope(WaterDesc* desc) @local {
    float total;
    foreach (&wave : desc.waves[:desc.wave_count]) total += wave.amplitude * 2 * (float)math::PI / wave.wavelength;
    return total;
}

fn InversionReport inversion_report(Fixture* fixture, WaterDesc desc) @local {
    Node* node = add_water_node(fixture, desc);
    SurfaceView view = water::surface_view(&fixture.scene, &fixture.assets, node.id)!!;

    // The iterate of a k-contraction lies within k / (1 - k) times its last step of the fixed point.
    float contraction = mean_steepness(&desc);
    float height_error_per_residual = height_slope(&desc) * contraction / (1 - contraction);
    InversionReport report = { .largest_excess = -float::max };

    for (uint sample = 0; sample < ERROR_TIMES; sample++) {
        double time = (double)sample * ERROR_TIME_STEP;
        for (uint row = 0; row < ERROR_GRID; row++) {
            for (uint column = 0; column < ERROR_GRID; column++) {
                Truth point = displaced(
                    desc:   &desc,
                    rest_x: (double)column,
                    rest_z: (double)row,
                    time:   time,
                );

                WaterSample detail = detail_at(&view, { (float)point.x, 0, (float)point.z }, time);
                float error = (float)math::abs(detail.height - point.y);

                report.largest_residual = max(report.largest_residual, detail.residual);
                report.largest_excess = max(report.largest_excess, error - detail.residual * height_error_per_residual);
            }
        }
    }
    return report;
}

fn void test_inversion_converges_to_the_tolerance() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    InversionReport gentle = inversion_report(&fixture, choppy_desc(GENTLE_STEEPNESS));
    assert(gentle.largest_residual <= water::WATER_QUERY_TOLERANCE, "residual %e", gentle.largest_residual);

    InversionReport steep = inversion_report(&fixture, choppy_desc(STEEP_STEEPNESS));
    assert(steep.largest_excess <= ROUNDING_SLACK, "height error passed its residual bound by %e", steep.largest_excess);
}

fn void test_invalid_desc_values_are_invalid_argument() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = fixture.scene.add_node()!!;
    uint free_nodes = fixture.scene.world.entities.free_count;
    uint free_materials = fixture.assets.materials.free_count;

    WaterDesc past_bound = calm_desc();
    past_bound.waves[0].steepness = 0.5f;
    past_bound.waves[1].steepness = 1.5001f;
    assert_fault(@catch(try_add(&fixture, node, past_bound)), c3d::INVALID_ARGUMENT, "A mean steepness past 1");
    WaterDesc aliased = calm_desc();
    aliased.cell_size = 1.25f;
    aliased.waves[1].wavelength = 2.49f;
    assert_fault(@catch(try_add(&fixture, node, aliased)), c3d::INVALID_ARGUMENT, "A wave shorter than two cells");
    WaterDesc[12] rejected;
    foreach (&desc : rejected) *desc = calm_desc();
    rejected[0].wave_count = water::MAX_WAVES + 1;
    rejected[1].waves[0].wavelength = 0;
    rejected[2].waves[0].direction = { 0.6f, 0.7f };
    rejected[3].waves[0].amplitude = -0.1f;
    rejected[4].waves[0].speed = float::nan;
    rejected[5].extent = 0;
    rejected[6].extent = (water::MAX_GRID_CELLS + 1) * rejected[6].cell_size;
    rejected[7].absorption_color = { 0, 0.5f, 0.5f };
    rejected[8].absorption_color = { 1.1f, 0.5f, 0.5f };
    rejected[9].roughness = 1.5f;
    rejected[10].foam_crest = 1;
    rejected[11].ripple_drift = float::nan;
    foreach (index, desc : rejected) {
        assert_fault(@catch(try_add(&fixture, node, desc)), c3d::INVALID_ARGUMENT, "A rejected desc");
    }
    assert(!fixture.scene.has(node, Water) && !fixture.scene.has(node, Mesh) && !fixture.scene.has(node, WaterRuntime));
    assert(fixture.scene.world.entities.free_count == free_nodes);
    assert(fixture.assets.materials.free_count == free_materials);

    WaterDesc under_bound = past_bound;
    under_bound.waves[1].steepness = 1.4999f;
    try_add(&fixture, node, under_bound)!!;
    WaterDesc two_cells = aliased;
    two_cells.waves[1].wavelength = 2.5f;
    try_add(&fixture, fixture.scene.add_node()!!, two_cells)!!;
}

fn void test_references_must_be_live_standard_materials() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = fixture.scene.add_node()!!;
    MaterialId standard = fixture.assets.add_material(material::standard())!!;
    MaterialId basic = fixture.assets.add_material(material::basic())!!;
    MaterialId removed = fixture.assets.add_material(material::standard())!!;
    fixture.assets.remove_material(removed);

    WaterDesc dead = calm_desc();
    dead.ripples = removed;
    assert_fault(@catch(try_add(&fixture, node, dead)), c3d::INVALID_ID, "A removed ripple material");
    WaterDesc unlit = calm_desc();
    unlit.foam = basic;
    assert_fault(@catch(try_add(&fixture, node, unlit)), c3d::INVALID_ARGUMENT, "A BASIC foam material");
    WaterDesc gone = calm_desc();
    @pool() {
        Geometry plane = geometry::plane(tmem, 10, 10, 4, 4);
        gone.geometry = fixture.assets.add_geometry(&plane)!!;
    };
    fixture.assets.remove_geometry(gone.geometry);
    assert_fault(@catch(try_add(&fixture, node, gone)), c3d::INVALID_ID, "A removed geometry");

    WaterDesc referenced = calm_desc();
    referenced.ripples = standard;
    referenced.foam = standard;
    try_add(&fixture, node, referenced)!!;
    MaterialId owned = fixture.scene.get(node, WaterRuntime).material;
    CustomParams* custom = &fixture.assets.material(owned).data.custom;
    assert(c3d::same_id(custom.references[0], standard) && c3d::same_id(custom.references[1], standard));
}

fn void test_application_geometry_must_rest_flat() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    GeometryId plane;
    GeometryId block;
    @pool() {
        Geometry flat = geometry::plane(tmem, 30, 10, 6, 2);
        plane = fixture.assets.add_geometry(&flat)!!;
        Geometry solid = geometry::box(tmem, 1, 1, 1);
        block = fixture.assets.add_geometry(&solid)!!;
    };

    WaterDesc raised = calm_desc();
    raised.geometry = block;
    Node* node = fixture.scene.add_node()!!;
    assert_fault(@catch(try_add(&fixture, node, raised)), c3d::INVALID_ARGUMENT, "A box as rest surface");
    WaterDesc flat = calm_desc();
    flat.geometry = plane;
    flat.extent = 0;
    node = add_water_node(&fixture, flat);
    Mesh* mesh = fixture.scene.get(node, Mesh);
    assert(c3d::same_id(mesh.geometry, plane));
    assert(c3d::same_id(fixture.scene.get(node, WaterRuntime).grid, plane));
    Aabb rest = fixture.assets.geometry(plane).data.bounds;
    assert(mesh.local_bounds.min.x < rest.min.x && mesh.local_bounds.max.z > rest.max.z);
}

fn void test_bounds_grow_by_amplitude_and_crest_shift() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    WaterDesc desc = calm_desc();
    desc.extent = 20;
    desc.waves[0] = { .amplitude = 0.3f, .wavelength = 4, .speed = 1, .direction = { 1, 0 }, .steepness = 0.8f };
    desc.wave_count = 1;
    Node* node = add_water_node(&fixture, desc);

    Mesh* mesh = fixture.scene.get(node, Mesh);
    float shift = 0.8f * 4 / (2 * (float)math::PI);
    assert(math::abs(mesh.local_bounds.max.x - (10 + shift)) <= QUERY_TOLERANCE);
    assert(math::abs(mesh.local_bounds.min.z + (10 + shift)) <= QUERY_TOLERANCE);
    assert(math::abs(mesh.local_bounds.max.y - 0.3f) <= QUERY_TOLERANCE);
    assert(math::abs(mesh.local_bounds.min.y + 0.3f) <= QUERY_TOLERANCE);
    assert(mesh.has_bounds_override && !mesh.cast_shadow && mesh.receive_shadow && !mesh.trace);
    assert(fixture.assets.geometry(mesh.geometry).vertex_count == 21 * 21);
}

fn void test_grid_is_shared_per_shape_and_kept() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    WaterDesc coarse = calm_desc();
    coarse.extent = 20;
    WaterDesc fine = coarse;
    fine.cell_size = 0.5f;
    Node* first = add_water_node(&fixture, coarse);
    Node* second = add_water_node(&fixture, coarse);
    Node* third = add_water_node(&fixture, fine);

    GeometryId coarse_grid = fixture.scene.get(first, WaterRuntime).grid;
    GeometryId fine_grid = fixture.scene.get(third, WaterRuntime).grid;
    assert(c3d::same_id(coarse_grid, fixture.scene.get(second, WaterRuntime).grid));
    assert(!c3d::same_id(coarse_grid, fine_grid));
    assert(c3d::same_id(fixture.assets.find_geometry("c3d_landscape/water_grid/0x1.4p+4/0x1p+0")!!, coarse_grid));

    try_set_desc(&fixture, first, fine)!!;
    assert(c3d::same_id(fixture.scene.get(first, WaterRuntime).grid, fine_grid));
    assert(c3d::same_id(fixture.scene.get(first, Mesh).geometry, fine_grid));
    fixture.scene.remove(second);
    update_water(&fixture);
    assert(fixture.assets.geometries.is_live(coarse_grid));
}

fn void test_failed_set_desc_keeps_everything() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    WaterDesc desc = calm_desc();
    Node* node = add_water_node(&fixture, desc);
    WaterRuntime* runtime = fixture.scene.get(node, WaterRuntime);
    char[] payload = fixture.assets.material(runtime.material).data.custom.param_block;
    char[WaterParams::size] before = payload[:WaterParams::size];
    uint revision = fixture.assets.material(runtime.material).header.revision;
    Mesh mesh = *fixture.scene.get(node, Mesh);
    SurfaceView old_view = water::surface_view(&fixture.scene, &fixture.assets, node.id)!!;

    WaterDesc invalid = desc;
    invalid.waves[0].steepness = 2;
    invalid.cell_size = 0.5f;
    assert_fault(@catch(try_set_desc(&fixture, node, invalid)), c3d::INVALID_ARGUMENT, "A mean steepness of 1.25");
    foreach (index, byte : before) assert(payload[index] == byte);
    assert(fixture.assets.material(runtime.material).header.revision == revision);
    Aabb kept = fixture.scene.get(node, Mesh).local_bounds;
    assert(kept.min == mesh.local_bounds.min && kept.max == mesh.local_bounds.max);
    assert(c3d::same_id(fixture.scene.get(node, Mesh).geometry, mesh.geometry));
    assert(fixture.scene.get(node, Water).desc.waves[0].steepness == desc.waves[0].steepness);

    WaterDesc taller = desc;
    taller.waves[0].amplitude = 0.3f;
    try_set_desc(&fixture, node, taller)!!;
    assert(fixture.assets.material(runtime.material).header.revision == revision + 1);
    assert(c3d::same_id(fixture.scene.get(node, Mesh).geometry, mesh.geometry));
    assert(fixture.scene.get(node, Mesh).local_bounds.max.y > mesh.local_bounds.max.y);
    SurfaceView new_view = water::surface_view(&fixture.scene, &fixture.assets, node.id)!!;
    float old_height = height_at(&old_view, 1.5f, 0, 0)!!;
    float new_height = height_at(&new_view, 1.5f, 0, 0)!!;
    assert(math::abs(new_height - old_height) > 0.1f);
}

fn void test_live_desc_edits_wait_for_set_desc() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    MaterialId ripples = fixture.assets.add_material(material::standard())!!;
    WaterDesc desc = calm_desc();
    desc.ripples = ripples;
    Node* edited = add_water_node(&fixture, desc, { 0, 2, 0 });
    Node* twin = add_water_node(&fixture, desc, { 0, 2, 0 });
    WaterDesc* live = &fixture.scene.get(edited, Water).desc;
    live.wave_count = water::MAX_WAVES + 3;
    live.waves[0].amplitude = float::nan;
    live.ripple_drift = float::nan;
    live.extent = 7;

    update_water(&fixture, { 4, 0, 3 }, 2);
    try_update_mirror(&fixture, edited.id)!!;
    try_update_mirror(&fixture, twin.id)!!;
    WaterRuntime* edited_runtime = fixture.scene.get(edited, WaterRuntime);
    WaterRuntime* twin_runtime = fixture.scene.get(twin, WaterRuntime);
    assert(edited_runtime.clip_plane.normal == twin_runtime.clip_plane.normal);
    assert(edited_runtime.clip_plane.d == twin_runtime.clip_plane.d);
    char[] edited_payload = fixture.assets.material(edited_runtime.material).data.custom.param_block;
    char[] twin_payload = fixture.assets.material(twin_runtime.material).data.custom.param_block;
    foreach (index, byte : twin_payload[:WaterParams::size]) assert(edited_payload[index] == byte);
    Mat4 edited_mirror = fixture.scene.node(edited_runtime.mirrors[0]).world;
    Mat4 twin_mirror = fixture.scene.node(twin_runtime.mirrors[0]).world;
    for (uint index = 0; index < 16; index++) assert(edited_mirror.m[index] == twin_mirror.m[index]);
    SurfaceView edited_view = water::surface_view(&fixture.scene, &fixture.assets, edited.id)!!;
    SurfaceView twin_view = water::surface_view(&fixture.scene, &fixture.assets, twin.id)!!;
    assert(height_at(&edited_view, 1.5f, 0.5f, 2)!! == height_at(&twin_view, 1.5f, 0.5f, 2)!!);
    assert(height_at(&edited_view, 60, -40, 2)!! == height_at(&twin_view, 60, -40, 2)!!);
}

fn void test_surface_follows_the_node_pose() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    WaterDesc desc = calm_desc();
    desc.extent = 20;
    desc.waves[0] = { .amplitude = 0.2f, .wavelength = 5, .speed = 1.5f, .direction = { 0.6f, 0.8f }, .steepness = 0 };
    desc.wave_count = 1;
    Node* node = add_water_node(
        fixture:     &fixture,
        desc:        desc,
        position:    WATER_POSITION,
        yaw_degrees: WATER_YAW_DEGREES,
    );
    SurfaceView view = water::surface_view(&fixture.scene, &fixture.assets, node.id)!!;

    Vec2[3] local_points = { { 1, 2 }, { -7, 4.5f }, { 9.5f, -9.5f } };
    foreach (local : local_points) {
        Vec3 world = maths::transform_point(node.world, { local.x, 0, local.y });
        double time = 2.25;
        float height = height_at(&view, world.x, world.z, time)!!;
        Truth truth = displaced(
            desc:   &desc,
            rest_x: local.x,
            rest_z: local.y,
            time:   time,
        );
        assert(math::abs(height - (WATER_POSITION.y + (float)truth.y)) <= QUERY_TOLERANCE);
    }
    Vec3 inside = maths::transform_point(node.world, { 9.9f, 0, 0 });
    Vec3 outside = maths::transform_point(node.world, { 10.1f, 0, 0 });
    height_at(&view, inside.x, inside.z, 0)!!;
    assert_fault(@catch(height_at(&view, outside.x, outside.z, 0)), NOT_FOUND, "A point past the edge");

    WaterSample[DETAIL_POINTS.len] before;
    foreach (index, local : DETAIL_POINTS) {
        Vec3 world = maths::transform_point(node.world, { local.x, 0, local.y });
        before[index] = detail_at(&view, world, DETAIL_TIMES[0]);
    }

    fixture.scene.shift_origin(ORIGIN_SHIFT);
    fixture.scene.update_world();
    SurfaceView shifted_view = water::surface_view(&fixture.scene, &fixture.assets, node.id)!!;
    foreach (index, local : DETAIL_POINTS) {
        Vec3 world = maths::transform_point(node.world, { local.x, 0, local.y });
        WaterSample after = detail_at(&shifted_view, world, DETAIL_TIMES[0]);
        assert(math::abs(after.height - before[index].height) <= QUERY_TOLERANCE);
        assert((after.normal - before[index].normal).length() <= QUERY_TOLERANCE);
        assert((after.velocity - before[index].velocity).length() <= QUERY_TOLERANCE);
    }

    Vec3 shifted_centre = maths::transform_point(node.world, { 0, 0, 0 });
    WaterSample? stale = water::sample_surface_detail(
        view:    &view,
        world_x: shifted_centre.x,
        world_z: shifted_centre.z,
        time:    DETAIL_TIMES[0],
    );
    assert_fault(@catch(stale), NOT_FOUND, "A view taken before the shift");
}

fn void test_surface_detail_follows_the_public_surface() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = add_water_node(
        fixture:     &fixture,
        desc:        calm_desc(),
        position:    WATER_POSITION,
        yaw_degrees: WATER_YAW_DEGREES,
    );
    SurfaceView view = water::surface_view(&fixture.scene, &fixture.assets, node.id)!!;
    WaterFluid fluid = { .view = view, .current = CURRENT };

    foreach (local : DETAIL_POINTS) {
        Vec3 point = maths::transform_point(node.world, { local.x, 0, local.y });
        foreach (time : DETAIL_TIMES) {
            WaterSample detail = detail_at(&view, point, time);
            SurfaceSlopes slopes = slopes_at(&view, point, time);
            assert(detail.height == height_over(&view, point, time));

            float kinematic = detail.velocity.y - (detail.velocity.x * slopes.x + detail.velocity.z * slopes.z);
            float kinematic_error = math::abs(kinematic - slopes.time);
            assert(kinematic_error <= KINEMATIC_TOLERANCE, "kinematic error %e at %f s", kinematic_error, time);

            Vec3 graph_normal = { -slopes.x, 1, -slopes.z };
            float normal_error = (detail.normal - graph_normal.normalize()).length();
            assert(normal_error <= NORMAL_TOLERANCE, "normal error %e at %f s", normal_error, time);

            fluid.time = time;
            Vec3 velocity;
            float height = water::fluid_sample(
                context:     &fluid,
                x:           point.x,
                z:           point.z,
                step_offset: SAMPLER_OFFSET,
                velocity:    &velocity,
            )!!;

            WaterSample offset_detail = detail_at(&view, point, time + (double)SAMPLER_OFFSET);
            assert(height == offset_detail.height);
            assert(velocity == offset_detail.velocity + CURRENT);
        }
    }

    Vec3 velocity;
    Vec3 outside = maths::transform_point(node.world, { 2 * calm_desc().extent, 0, 0 });

    float? sampled = water::fluid_sample(
        context:     &fluid,
        x:           outside.x,
        z:           outside.z,
        step_offset: 0,
        velocity:    &velocity,
    );
    assert_fault(@catch(sampled), NOT_FOUND, "A point past the edge");
}

fn void place_camera(Fixture* fixture, Node* camera, Vec3 position, float pitch_degrees) @local {
    camera.local.position = position;
    camera.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, (float)math::deg_to_rad(pitch_degrees));
    fixture.scene.get(camera, Camera).layers = camera::ALL_LAYERS;
    fixture.scene.update_world();
}

fn void test_each_mirror_slot_reflects_its_viewing_camera() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    WaterDesc desc = calm_desc();
    desc.max_mirrors = 2;
    Node* node = add_water_node(&fixture, desc, { 0, 2, 0 });
    node.layers = WATER_LAYER | 1;
    Node* second = fixture.scene.add_camera(camera::perspective_deg(40, 0.5f))!!;
    place_camera(&fixture, fixture.camera, { 1, 5, 8 }, -20);
    place_camera(&fixture, second, { -6, 9, -3 }, -35);
    try_update_mirror(&fixture, node.id, 0, fixture.camera.id)!!;
    try_update_mirror(&fixture, node.id, 1, second.id)!!;

    WaterRuntime* runtime = fixture.scene.get(node, WaterRuntime);
    Plane rest = { .normal = { 0, 1, 0 }, .d = -2 };
    Node*[2] viewing = { fixture.camera, second };
    assert(!c3d::same_id(runtime.mirrors[0], runtime.mirrors[1]));
    foreach (slot, camera : viewing) {
        Node* mirror = fixture.scene.node(runtime.mirrors[slot]);
        Mat4 expected = maths::reflection_matrix(rest).mul(camera.world);
        for (uint index = 0; index < 16; index++) {
            assert(math::abs(mirror.world.m[index] - expected.m[index]) <= MATRIX_TOLERANCE);
        }
        assert(mirror.world.determinant() < 0);
        assert(mirror.parent == fixture.scene.root);
        WaterMirror* owner = fixture.scene.get(mirror, WaterMirror);
        assert(c3d::same_id(owner.water, node.id) && owner.slot == slot);
        Camera* mirrored = fixture.scene.get(mirror, Camera);
        Camera* lens = fixture.scene.get(camera, Camera);
        assert(mirrored.layers == (camera::ALL_LAYERS & ~(WATER_LAYER | 1)));
        assert(mirrored.fov_y == lens.fov_y && mirrored.near == lens.near && mirrored.aspect == lens.aspect);
    }
    assert(fixture.scene.count(WaterMirror) == 2);

    float amplitude = 0.12f + 0.07f;
    assert(runtime.clip_plane.normal == (Vec3){ 0, 1, 0 });
    assert(math::abs(runtime.clip_plane.d - (-2 + amplitude)) <= QUERY_TOLERANCE);
}

fn void test_released_mirror_slot_is_freed_and_placed_again_on_demand() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    WaterDesc desc = calm_desc();
    desc.max_mirrors = 3;
    Node* node = add_water_node(&fixture, desc, { 0, 2, 0 });
    WaterRuntime* runtime = fixture.scene.get(node, WaterRuntime);
    Entity kept = runtime.mirrors[0];
    Entity released = runtime.mirrors[1];
    assert(fixture.scene.count(WaterMirror) == 3);

    water::release_mirror(&fixture.scene, node.id, 1);
    assert(!fixture.scene.world.is_alive(released));
    assert(!runtime.mirrors[1].generation);
    assert(fixture.scene.world.is_alive(kept) && fixture.scene.count(WaterMirror) == 2);
    water::release_mirror(&fixture.scene, node.id, 1);
    assert(fixture.scene.count(WaterMirror) == 2);

    try_update_mirror(&fixture, node.id, 1)!!;
    assert(fixture.scene.world.is_alive(runtime.mirrors[1]) && fixture.scene.count(WaterMirror) == 3);
    assert(fixture.scene.get(fixture.scene.node(runtime.mirrors[1]), WaterMirror).slot == 1);

    WaterDesc narrower = desc;
    narrower.max_mirrors = 1;
    try_set_desc(&fixture, node, narrower)!!;
    assert(c3d::same_id(runtime.mirrors[0], kept) && fixture.scene.count(WaterMirror) == 1);
    assert(!runtime.mirrors[1].generation && !runtime.mirrors[2].generation);
}

fn void test_update_mirror_faults_without_a_body_or_camera() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = add_water_node(&fixture, calm_desc());
    Node* plain = fixture.scene.add_node()!!;
    Node* gone = fixture.scene.add_camera(camera::perspective_deg(60, 0.1f))!!;
    Entity dead_camera = gone.id;
    fixture.scene.remove(gone);
    Node* pending = fixture.scene.add_node()!!;
    water::attach_water(
        scene:  &fixture.scene,
        assets: &fixture.assets,
        node:   pending,
        desc:   calm_desc(),
    )!!;

    Entity dead_body = fixture.scene.add_node()!!.id;
    fixture.scene.remove(fixture.scene.node(dead_body));
    assert_fault(@catch(try_update_mirror(&fixture, plain.id)), c3d::INVALID_ID, "A node without water");
    assert_fault(@catch(try_update_mirror(&fixture, pending.id)), c3d::INVALID_ID, "Pending water");
    assert_fault(@catch(try_update_mirror(&fixture, dead_body)), c3d::INVALID_ID, "A dead body");
    assert_fault(@catch(try_update_mirror(&fixture, node.id, 0, dead_camera)), c3d::INVALID_ID, "A dead camera");
}

fn void test_view_slot_and_mirror_count_are_checked_at_add() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = fixture.scene.add_node()!!;
    WaterDesc[3] rejected;
    foreach (&desc : rejected) *desc = calm_desc();
    rejected[0].reflection_view_slot = material::MAX_VIEW_TEXTURES;
    rejected[1].max_mirrors = 0;
    rejected[2].max_mirrors = water::MAX_MIRRORS + 1;
    foreach (desc : rejected) {
        assert_fault(@catch(try_add(&fixture, node, desc)), c3d::INVALID_ARGUMENT, "A rejected slot value");
    }
    assert(!fixture.scene.has(node, Water) && !fixture.scene.has(node, WaterRuntime));
    assert(fixture.scene.count(WaterMirror) == 0);

    WaterDesc last = calm_desc();
    last.reflection_view_slot = material::MAX_VIEW_TEXTURES - 1;
    last.max_mirrors = water::MAX_MIRRORS;
    try_add(&fixture, node, last)!!;
    WaterRuntime* runtime = fixture.scene.get(node, WaterRuntime);
    TextureSlot slot = fixture.assets.material(runtime.material).data.custom.slots[0];
    assert(slot.texture.kind == VIEW && slot.texture.view_slot == material::MAX_VIEW_TEXTURES - 1);
    assert(fixture.scene.count(WaterMirror) == water::MAX_MIRRORS);

    WaterDesc moved = last;
    moved.reflection_view_slot = 1;
    try_set_desc(&fixture, node, moved)!!;
    assert(fixture.assets.material(runtime.material).data.custom.slots[0].texture.view_slot == 1);
    moved.reflection_view_slot = material::MAX_VIEW_TEXTURES;
    assert_fault(@catch(try_set_desc(&fixture, node, moved)), c3d::INVALID_ARGUMENT, "A view slot past the limit");
    assert(fixture.assets.material(runtime.material).data.custom.slots[0].texture.view_slot == 1);
}

fn Vec2 texture_phase(Vec2 offset, UvTransform transform) @local {
    float cosine = math::cos(transform.rotation);
    float sine = math::sin(transform.rotation);
    Vec2 scaled = offset * transform.scale;
    Vec2 texture = { cosine * scaled.x - sine * scaled.y, sine * scaled.x + cosine * scaled.y };
    return texture - math::floor(texture);
}

fn float phase_distance(Vec2 first, Vec2 second) @local {
    Vec2 difference = first - second;
    difference -= math::round(difference);
    return math::max(math::abs(difference.x), math::abs(difference.y));
}

fn void test_wind_change_keeps_the_ripple_offset_continuous() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    StandardParams ripple_params = material::STANDARD_PARAMS_DEFAULT;
    ripple_params.normal_map.transform = { .scale = { 0.25f, 0.4f }, .rotation = 0.3f };
    MaterialId ripples = fixture.assets.add_material(material::standard(ripple_params))!!;
    WaterDesc desc = calm_desc();
    desc.ripples = ripples;
    desc.ripple_drift = 0.05f;
    Node* node = add_water_node(
        fixture:     &fixture,
        desc:        desc,
        position:    WATER_POSITION,
        yaw_degrees: WATER_YAW_DEGREES,
    );
    MaterialId owned = fixture.scene.get(node, WaterRuntime).material;
    WaterParams* params = fixture.assets.@custom_params(owned, WaterParams);
    uint revision = fixture.assets.material(owned).header.revision;

    update_water(&fixture, { 4, 0, 3 }, 1);
    assert(fixture.assets.material(owned).header.revision == revision + 1);
    Vec3 local_wind = maths::transform_dir(maths::inverse_affine(node.world), { 4, 0, 3 });
    Vec2 first = (Vec2){ local_wind.x, local_wind.z } * 0.05f;
    assert((params.scroll_velocity.xy - first).length() <= QUERY_TOLERANCE);
    float cosine = math::cos(water::RIPPLE_CROSS_ANGLE);
    float sine = math::sin(water::RIPPLE_CROSS_ANGLE);
    Vec2 second = { cosine * first.x - sine * first.y, sine * first.x + cosine * first.y };
    assert((params.scroll_velocity.zw - second).length() <= QUERY_TOLERANCE);
    update_water(&fixture, { 4, 0, 3 }, 1.5);
    assert(fixture.assets.material(owned).header.revision == revision + 1);

    float change = (float)1000.25;
    Vec4 before = params.scroll_origin + params.scroll_velocity * (change - params.scroll_time);
    update_water(&fixture, { -2, 0, 6 }, 1000.25);
    Vec4 after = params.scroll_origin + params.scroll_velocity * (change - params.scroll_time);
    assert(fixture.assets.material(owned).header.revision == revision + 2);
    UvTransform transform = ripple_params.normal_map.transform;
    assert(phase_distance(texture_phase(before.xy, transform), texture_phase(after.xy, transform)) <= SCROLL_TOLERANCE);
    assert(phase_distance(texture_phase(before.zw, transform), texture_phase(after.zw, transform)) <= SCROLL_TOLERANCE);
    Vec2 origin = texture_phase(params.scroll_origin.xy, transform);
    Vec2 unwrapped = params.scroll_origin.xy * transform.scale;
    assert(unwrapped.length() <= 2 * (origin.length() + 1));
}

fn void test_removed_water_releases_material_and_mirror() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* first = add_water_node(&fixture, calm_desc());
    Node* second = add_water_node(&fixture, calm_desc());
    WaterRuntime first_runtime = *fixture.scene.get(first, WaterRuntime);
    WaterRuntime second_runtime = *fixture.scene.get(second, WaterRuntime);

    fixture.scene.remove_component(first, Water);
    update_water(&fixture);
    assert(!fixture.scene.has(first, Mesh) && !fixture.scene.has(first, WaterRuntime));
    assert(!fixture.assets.materials.is_live(first_runtime.material));
    assert(!fixture.scene.world.is_alive(first_runtime.mirrors[0]));

    fixture.scene.remove(second);
    assert(!fixture.assets.materials.is_live(second_runtime.material));
    update_water(&fixture);
    assert(!fixture.scene.world.is_alive(second_runtime.mirrors[0]));
    assert(fixture.assets.geometries.is_live(second_runtime.grid));
}

fn void test_pending_water_rolls_back_caches_and_preserves_prepared_owners() @test {
    Fixture fixture;
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&fixture.assets);
    fixture.scene = scene::create_scene(mem, { .max_nodes = 5 });
    defer scene::destroy_scene(&fixture.scene);
    water::register_water(&fixture.scene, &fixture.assets)!!;
    fixture.camera = fixture.scene.add_camera(camera::perspective_deg(60, 0.1f))!!;
    Node* first = fixture.scene.add_node()!!;
    Node* second = fixture.scene.add_node()!!;
    Node* first_blocker = fixture.scene.add_node()!!;
    Node* second_blocker = fixture.scene.add_node()!!;
    WaterDesc desc = calm_desc();
    desc.extent = 10;
    uint free_nodes = fixture.scene.world.entities.free_count;
    uint free_geometry = fixture.assets.geometries.free_count;
    uint free_shaders = fixture.assets.shaders.free_count;
    uint free_materials = fixture.assets.materials.free_count;
    water::attach_water(
        scene: &fixture.scene,
        assets: &fixture.assets,
        node: first,
        desc: desc,
    )!!;
    water::attach_water(
        scene: &fixture.scene,
        assets: &fixture.assets,
        node: second,
        desc: desc,
    )!!;
    assert(fixture.scene.count(Mesh) == 0 && fixture.scene.count(WaterMirror) == 0);
    assert(fixture.scene.world.entities.free_count == free_nodes);
    assert(fixture.assets.materials.free_count == free_materials);
    fixture.scene.update_world();
    update_water(&fixture);
    assert(fixture.scene.count(Mesh) == 0);

    assert(@catch(water::prepare(&fixture.scene, &fixture.assets, first)) == c3d::CAPACITY_EXCEEDED);
    assert(!water::is_prepared(&fixture.scene, first));
    assert(fixture.assets.geometries.free_count == free_geometry && fixture.assets.shaders.free_count == free_shaders);
    assert(fixture.assets.materials.free_count == free_materials);
    assert(fixture.scene.get(first, Water).desc.extent == desc.extent);
    fixture.scene.remove(first_blocker);
    assert(@catch(water::prepare_subtree(&fixture.scene, &fixture.assets)) == c3d::CAPACITY_EXCEEDED);
    assert(water::is_prepared(&fixture.scene, first) && !water::is_prepared(&fixture.scene, second));
    WaterRuntime before = *fixture.scene.get(first, WaterRuntime);
    update_water(&fixture);
    assert(fixture.scene.has(first, Mesh) && !fixture.scene.has(second, Mesh));
    assert(fixture.scene.world.is_alive(before.mirrors[0]));

    fixture.scene.remove(second_blocker);
    water::prepare(&fixture.scene, &fixture.assets, second)!!;
    free_geometry = fixture.assets.geometries.free_count;
    free_materials = fixture.assets.materials.free_count;
    water::prepare_subtree(&fixture.scene, &fixture.assets)!!;
    assert(fixture.assets.geometries.free_count == free_geometry && fixture.assets.materials.free_count == free_materials);
    assert(c3d::same_id(fixture.scene.get(first, WaterRuntime).mirrors[0], before.mirrors[0]));
    assert(c3d::same_id(fixture.scene.get(first, WaterRuntime).material, before.material));
    assert(fixture.scene.count(Mesh) == 2 && fixture.scene.count(WaterMirror) == 2);
    update_water(&fixture);
}

fn void test_water_eager_failure_and_pending_removal_leave_no_owned_resources() @test {
    TrackingAllocator tracking;
    tracking.init(mem);
    defer tracking.free();
    Fixture fixture;
    fixture.assets = asset::create_asset_store(&tracking, asset::default_asset_store_desc());
    fixture.scene = scene::create_scene(&tracking, { .max_nodes = 2 });
    water::register_water(&fixture.scene, &fixture.assets)!!;
    fixture.camera = fixture.scene.add_camera(camera::perspective_deg(60, 0.1f))!!;
    Node* node = fixture.scene.add_node()!!;
    fixture.scene.update_world();
    WaterDesc desc = calm_desc();
    desc.extent = 10;
    uint free_geometry = fixture.assets.geometries.free_count;
    uint free_shaders = fixture.assets.shaders.free_count;
    uint free_materials = fixture.assets.materials.free_count;
    uint free_nodes = fixture.scene.world.entities.free_count;
    assert(@catch(try_add(&fixture, node, desc)) == c3d::CAPACITY_EXCEEDED);
    assert(!fixture.scene.has(node, Water) && !fixture.scene.has(node, WaterRuntime));
    assert(!fixture.scene.has(node, Mesh) && fixture.scene.count(WaterMirror) == 0);
    assert(fixture.assets.geometries.free_count == free_geometry && fixture.assets.shaders.free_count == free_shaders);
    assert(fixture.assets.materials.free_count == free_materials && fixture.scene.world.entities.free_count == free_nodes);
    sz bytes = tracking.allocated();
    water::attach_water(
        scene: &fixture.scene,
        assets: &fixture.assets,
        node: node,
        desc: desc,
    )!!;
    assert(!water::is_prepared(&fixture.scene, node) && tracking.allocated() == bytes);
    fixture.scene.remove_component(node, Water);
    assert(!fixture.scene.has(node, Water) && !fixture.scene.has(node, WaterRuntime));
    assert(!fixture.scene.has(node, Mesh) && tracking.allocated() == bytes);
    teardown(&fixture);
    assert(!tracking.has_leaks());
}
