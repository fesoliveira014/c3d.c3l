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

const float CALM_BOUND @local = 0.0011f; // metres: the calm set's measured 1.05 mm after three steps, rounded up
const float CHOPPY_BOUND @local = 0.0068f; // metres: the choppy set's measured 6.71 mm, rounded up
const uint ERROR_GRID @local = 64; // rest points per side, one metre apart
const uint ERROR_TIMES @local = 8;
const double ERROR_TIME_STEP @local = 0.37;
const float QUERY_TOLERANCE @local = 0.0001f; // metres; float rounding of the rotated node
const float MATRIX_TOLERANCE @local = 0.00001f;
const float SCROLL_TOLERANCE @local = 0.0001f; // texture-space periods; float rounding of the segment change
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

fn WaterDesc choppy_desc() @local {
    WaterDesc desc = calm_desc();
    desc.waves = {
        { .amplitude = 0.35f, .wavelength = 12, .speed = 2.5f, .direction = { 1, 0 }, .steepness = 0.8f },
        { .amplitude = 0.2f, .wavelength = 7, .speed = 1.9f, .direction = { 0.8f, 0.6f }, .steepness = 0.8f },
        { .amplitude = 0.12f, .wavelength = 4, .speed = 1.4f, .direction = { 0.28f, 0.96f }, .steepness = 0.8f },
        { .amplitude = 0.06f, .wavelength = 2, .speed = 1.0f, .direction = { -0.6f, 0.8f }, .steepness = 0.8f },
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

fn void? try_update(Fixture* fixture, Vec3 wind = {}, double time = 0) @local {
    return water::update(
        scene:          &fixture.scene,
        assets:         &fixture.assets,
        viewing_camera: fixture.camera.id,
        wind_velocity:  wind,
        time:           time,
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

fn float largest_inversion_error(Fixture* fixture, WaterDesc desc) @local {
    Node* node = add_water_node(fixture, desc);
    SurfaceView view = water::surface_view(&fixture.scene, &fixture.assets, node.id)!!;
    float worst;
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
                float height = height_at(&view, (float)point.x, (float)point.z, time)!!;
                worst = max(worst, (float)math::abs(height - point.y));
            }
        }
    }
    return worst;
}

fn void test_inversion_error_stays_under_the_stated_bound() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);

    assert(largest_inversion_error(&fixture, calm_desc()) <= CALM_BOUND);
    assert(largest_inversion_error(&fixture, choppy_desc()) <= CHOPPY_BOUND);
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
    try_update(&fixture)!!;
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

    try_update(&fixture, { 4, 0, 3 }, 2)!!;
    WaterRuntime* edited_runtime = fixture.scene.get(edited, WaterRuntime);
    WaterRuntime* twin_runtime = fixture.scene.get(twin, WaterRuntime);
    assert(edited_runtime.clip_plane.normal == twin_runtime.clip_plane.normal);
    assert(edited_runtime.clip_plane.d == twin_runtime.clip_plane.d);
    char[] edited_payload = fixture.assets.material(edited_runtime.material).data.custom.param_block;
    char[] twin_payload = fixture.assets.material(twin_runtime.material).data.custom.param_block;
    foreach (index, byte : twin_payload[:WaterParams::size]) assert(edited_payload[index] == byte);
    Mat4 edited_mirror = fixture.scene.node(edited_runtime.mirror).world;
    Mat4 twin_mirror = fixture.scene.node(twin_runtime.mirror).world;
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
}

fn void test_mirror_reflects_the_viewing_camera() @test {
    Fixture fixture;
    setup(&fixture);
    defer teardown(&fixture);
    Node* node = add_water_node(&fixture, calm_desc(), { 0, 2, 0 });
    node.layers = WATER_LAYER | 1;
    fixture.camera.local.position = { 1, 5, 8 };
    fixture.camera.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, (float)math::deg_to_rad(-20));
    fixture.scene.get(fixture.camera, Camera).layers = camera::ALL_LAYERS;
    fixture.scene.update_world();
    try_update(&fixture)!!;

    WaterRuntime* runtime = fixture.scene.get(node, WaterRuntime);
    Node* mirror = fixture.scene.node(runtime.mirror);
    Plane rest = { .normal = { 0, 1, 0 }, .d = -2 };
    Mat4 expected = maths::reflection_matrix(rest).mul(fixture.camera.world);
    fixture.scene.update_world();
    for (uint index = 0; index < 16; index++) {
        assert(math::abs(mirror.world.m[index] - expected.m[index]) <= MATRIX_TOLERANCE);
    }
    assert(mirror.world.determinant() < 0);
    assert(mirror.parent == fixture.scene.root);
    assert(c3d::same_id(fixture.scene.get(mirror, WaterMirror).water, node.id));
    Camera* mirrored = fixture.scene.get(mirror, Camera);
    Camera* viewing = fixture.scene.get(fixture.camera, Camera);
    assert(mirrored.layers == (camera::ALL_LAYERS & ~(WATER_LAYER | 1)));
    assert(mirrored.fov_y == viewing.fov_y && mirrored.near == viewing.near && mirrored.aspect == viewing.aspect);
    float amplitude = 0.12f + 0.07f;
    assert(runtime.clip_plane.normal == (Vec3){ 0, 1, 0 });
    assert(math::abs(runtime.clip_plane.d - (-2 + amplitude)) <= QUERY_TOLERANCE);

    uint revision = fixture.assets.material(runtime.material).header.revision;
    RenderTargetId target = { .index = 3, .generation = 1 };
    water::set_reflection_target(&fixture.scene, &fixture.assets, node, target);
    TextureSlot slot = fixture.assets.material(runtime.material).data.custom.slots[0];
    assert(slot.texture.kind == RENDER_TARGET && c3d::same_id(slot.texture.target, target));
    assert(fixture.assets.material(runtime.material).header.revision == revision + 1);
    water::set_reflection_target(&fixture.scene, &fixture.assets, node, {});
    assert(fixture.assets.material(runtime.material).data.custom.slots[0].texture.kind == ASSET);
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

    try_update(&fixture, { 4, 0, 3 }, 1)!!;
    assert(fixture.assets.material(owned).header.revision == revision + 1);
    Vec3 local_wind = maths::transform_dir(maths::inverse_affine(node.world), { 4, 0, 3 });
    Vec2 first = (Vec2){ local_wind.x, local_wind.z } * 0.05f;
    assert((params.scroll_velocity.xy - first).length() <= QUERY_TOLERANCE);
    float cosine = math::cos(water::RIPPLE_CROSS_ANGLE);
    float sine = math::sin(water::RIPPLE_CROSS_ANGLE);
    Vec2 second = { cosine * first.x - sine * first.y, sine * first.x + cosine * first.y };
    assert((params.scroll_velocity.zw - second).length() <= QUERY_TOLERANCE);
    try_update(&fixture, { 4, 0, 3 }, 1.5)!!;
    assert(fixture.assets.material(owned).header.revision == revision + 1);

    float change = (float)1000.25;
    Vec4 before = params.scroll_origin + params.scroll_velocity * (change - params.scroll_time);
    try_update(&fixture, { -2, 0, 6 }, 1000.25)!!;
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
    try_update(&fixture)!!;
    assert(!fixture.scene.has(first, Mesh) && !fixture.scene.has(first, WaterRuntime));
    assert(!fixture.assets.materials.is_live(first_runtime.material));
    assert(!fixture.scene.world.is_alive(first_runtime.mirror));

    fixture.scene.remove(second);
    assert(!fixture.assets.materials.is_live(second_runtime.material));
    try_update(&fixture)!!;
    assert(!fixture.scene.world.is_alive(second_runtime.mirror));
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
    try_update(&fixture)!!;
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
    try_update(&fixture)!!;
    assert(fixture.scene.has(first, Mesh) && !fixture.scene.has(second, Mesh));
    assert(fixture.scene.world.is_alive(before.mirror));

    fixture.scene.remove(second_blocker);
    water::prepare(&fixture.scene, &fixture.assets, second)!!;
    free_geometry = fixture.assets.geometries.free_count;
    free_materials = fixture.assets.materials.free_count;
    water::prepare_subtree(&fixture.scene, &fixture.assets)!!;
    assert(fixture.assets.geometries.free_count == free_geometry && fixture.assets.materials.free_count == free_materials);
    assert(c3d::same_id(fixture.scene.get(first, WaterRuntime).mirror, before.mirror));
    assert(c3d::same_id(fixture.scene.get(first, WaterRuntime).material, before.material));
    assert(fixture.scene.count(Mesh) == 2 && fixture.scene.count(WaterMirror) == 2);
    try_update(&fixture)!!;
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
