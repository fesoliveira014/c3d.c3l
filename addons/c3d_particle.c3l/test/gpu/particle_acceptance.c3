module c3d::render::particle_acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::particle;
import c3d::render @public;
import c3d::scene;
import gpu;
import std::math;

const uint IMAGE_SIZE @private = 64;
const float VIEW_HEIGHT @private = 4;
const float PIXEL_TOLERANCE @private = 0.02f;
const Vec4 WHITE @private = { 1, 1, 1, 1 };
const Vec4 BLUE @private = { 0, 0, 1, 1 };

struct Fixture @private {
    AssetStore assets;
    Scene scene;
    Renderer renderer;
    Node*[2] cameras;
    RenderTargetId[2] targets;
    ViewId[2] views;
    ShaderId shader;
    MaterialId material;
    ParticleMaterialParams params;
}

fn void? create_fixture(Fixture* fixture) @private {
    fixture.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer catch asset::destroy_asset_store(&fixture.assets);
    fixture.scene = scene::create_scene(mem, { .max_nodes = 32 });
    defer catch scene::destroy_scene(&fixture.scene);
    particle::register_particles(&fixture.scene)!;
    fixture.scene.background.color = {};
    fixture.renderer = render::create_renderer(mem, &fixture.assets, { .validation = true })!;
    defer catch render::destroy_renderer(&fixture.renderer);
    fixture.shader = particle::add_particle_shader(&fixture.assets)!;
    fixture.params = { .color = WHITE };
    fixture.material = particle::add_particle_material(&fixture.assets, fixture.shader, fixture.params)!;
    foreach (index, &camera : fixture.cameras) {
        *camera = fixture.scene.add_camera(camera::orthographic(VIEW_HEIGHT, 0.1f, 100))!;
        (*camera).local.position = index ? (Vec3){ 5, 0, 0 } : (Vec3){ 0, 0, 5 };
        fixture.targets[index] = render::create_render_target(
            renderer: &fixture.renderer,
            desc: render::render_target_desc(IMAGE_SIZE, IMAGE_SIZE, PixelFormat.RGBA32_FLOAT),
        )!;
        ViewDesc desc = render::texture_view_desc(fixture.targets[index]);
        desc.post.anti_aliasing = AntiAliasing.NONE;
        fixture.views[index] = render::create_view(&fixture.renderer, desc)!;
    }
    fixture.scene.update_world();
    fixture.cameras[1].look_at({});
    fixture.scene.update_world();
}

fn void check_validation(Fixture* fixture) @private {
    DebugEntry[render::DEBUG_LOG_ENTRIES] entries;
    usz count = fixture.renderer.log.recent(entries[..]);
    foreach (entry : entries[:count]) {
        assert(!(entry.category.backend && entry.category.validation
            && entry.severity == gpu::DebugMessageSeverity.ERROR));
    }
}

fn void destroy_fixture(Fixture* fixture) @private {
    check_validation(fixture);
    render::destroy_renderer(&fixture.renderer);
    scene::destroy_scene(&fixture.scene);
    asset::destroy_asset_store(&fixture.assets);
}

fn Node* add_emitter(Fixture* fixture, ParticleSystemDesc desc, Vec3 position = {}) @private {
    if (!desc.material.generation) desc.material = fixture.material;
    Node* emitter = fixture.scene.add_particle_system(desc)!!;
    emitter.local.position = position;
    return emitter;
}

fn ParticleSystemDesc quiet_desc() @private {
    ParticleSystemDesc desc = particle::default_particle_system_desc();
    desc.capacity = 16;
    desc.lifetime = { .min = 5, .max = 5 };
    return desc;
}

fn void burst(Fixture* fixture, Node* emitter, uint count = 1) @private {
    fixture.scene.get(emitter, ParticleSystem).emit_burst(count);
    fixture.scene.update_world();
    particle::update(&fixture.scene, 0);
}

fn void render_frames(
    Fixture* fixture,
    bool both_views = false,
    uint frames = render::FRAMES_IN_FLIGHT + 1,
    Vec3 reference = {},
) @private {
    fixture.scene.update_world();
    for (uint frame = 0; frame < frames; frame++) {
        fixture.renderer.begin_frame({ .reference_position = reference })!!;
        for (uint view = 0; view < (both_views ? 2u : 1u); view++) {
            fixture.renderer.render_view(&fixture.scene, fixture.cameras[view], fixture.views[view])!!;
            fixture.renderer.finish_view(fixture.views[view])!!;
        }
        fixture.renderer.end_frame()!!;
    }
    check_validation(fixture);
}

fn Vec4[] read_pixels(Fixture* fixture, uint view = 0) @private {
    Vec4[] pixels = mem::new_array(Vec4, IMAGE_SIZE * IMAGE_SIZE);
    fixture.renderer.read_render_target(fixture.targets[view], ((char*)pixels.ptr)[:pixels.len * Vec4::size])!!;
    return pixels;
}

fn Vec4 pixel_at(Vec4[] pixels, Vec2 offset = {}) @private {
    uint x = (uint)((float)IMAGE_SIZE * (0.5f + offset.x / VIEW_HEIGHT));
    uint y = (uint)((float)IMAGE_SIZE * (0.5f - offset.y / VIEW_HEIGHT));
    return pixels[y * IMAGE_SIZE + x];
}

fn void check_pixel(Vec4 found, Vec4 expected) @private {
    for (uint channel = 0; channel < 4; channel++) {
        assert(math::is_finite(found[channel]));
        assert(math::abs(found[channel] - expected[channel]) <= PIXEL_TOLERANCE);
    }
}

fn Vec4 centre(Fixture* fixture) @private {
    render_frames(fixture);
    Vec4[] pixels = read_pixels(fixture);
    defer free(pixels);
    return pixel_at(pixels);
}

fn void test_particle_billboard_mesh_and_two_view_output() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Node* smoke = add_emitter(&fixture, quiet_desc(), { -1, 0, 0 });
    ParticleSystemDesc mesh = quiet_desc();
    mesh.render_mode = ParticleRenderMode.MESH;
    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        mesh.geometry = fixture.assets.add_geometry(&box)!!;
    };
    mesh.material = fixture.assets.add_material(material::basic({ .color = { 0, 1, 0, 1 } }))!!;
    Node* debris = add_emitter(&fixture, mesh, { 1, 0, 0 });
    burst(&fixture, smoke);
    burst(&fixture, debris);
    ParticleSystem* system = fixture.scene.get(smoke, ParticleSystem);
    uint particle_seed = system.seed[0];
    float age = system.age[0];
    render_frames(&fixture, true);
    Vec4[] front = read_pixels(&fixture);
    defer free(front);
    check_pixel(pixel_at(front, { -1, 0 }), WHITE);
    check_pixel(pixel_at(front, { 1, 0 }), { 0, 1, 0, 1 });
    Vec4[] side = read_pixels(&fixture, 1);
    defer free(side);
    check_pixel(pixel_at(side), { 0, 1, 0, 1 });
    render_frames(&fixture, true);
    assert(system.age[0] == age && system.seed[0] == particle_seed && system.alive == 1);
    assert(system.position[0] == (Vec3){ -1, 0, 0 });
}

fn void test_relative_particle_records_preserve_world_simulation_and_pixels() @test {
    for (uint mode = 0; mode < 2; mode++) {
        Fixture fixture;
        create_fixture(&fixture)!!;
        defer destroy_fixture(&fixture);
        Vec3 offset = { 65536, 0, 65536 };
        fixture.scene.root.local.position = offset;
        ParticleSystemDesc desc = quiet_desc();
        if (mode) {
            desc.render_mode = ParticleRenderMode.MESH;
            @pool() {
                Geometry box = geometry::box(
                    allocator: tmem,
                    width: 1,
                    height: 1,
                    depth: 1,
                );
                desc.geometry = fixture.assets.add_geometry(&box)!!;
            };
            desc.material = fixture.assets.add_material(material::basic({ .color = WHITE }))!!;
        }
        Node* emitter = add_emitter(&fixture, desc);
        burst(&fixture, emitter);
        ParticleSystem* system = fixture.scene.get(emitter, ParticleSystem);
        Vec3 position = system.position[0];
        uint seed = system.seed[0];
        render_frames(fixture: &fixture, both_views: true, reference: offset);
        Vec4[] reference = read_pixels(&fixture);
        defer free(reference);
        check_pixel(pixel_at(reference), WHITE);
        render_frames(fixture: &fixture, both_views: true, reference: offset + (Vec3){ 256, 0, -256 });
        Vec4[] found = read_pixels(&fixture);
        defer free(found);
        foreach (index, expected : reference) check_pixel(found[index], expected);
        assert(system.position[0] == position && position == offset);
        assert(system.seed[0] == seed && system.age[0] == 0);
    }
}

fn void test_particle_soft_depth_fade_and_hard_depth() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Node* emitter = add_emitter(&fixture, quiet_desc());
    burst(&fixture, emitter);
    GeometryId plane;
    @pool() {
        Geometry geometry = geometry::plane(tmem, 4, 4);
        plane = fixture.assets.add_geometry(&geometry)!!;
    };
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    MaterialId blue = fixture.assets.add_material(material::basic({ .color = BLUE }, common))!!;
    Node* background = fixture.scene.add_mesh(plane, blue)!!;
    background.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, (float)math::PI / 2);
    background.local.position.z = -0.25f;
    fixture.params.soft_distance = 0.5f;
    fixture.assets.@set_custom_params(fixture.material, fixture.params)!!;
    check_pixel(centre(&fixture), { 0.5f, 0.5f, 1, 1 });
    fixture.params.soft_distance = 0;
    fixture.assets.@set_custom_params(fixture.material, fixture.params)!!;
    check_pixel(centre(&fixture), WHITE);
    background.local.position.z = 0.25f;
    check_pixel(centre(&fixture), BLUE);
    fixture.params.soft_distance = 0.5f;
    fixture.assets.@set_custom_params(fixture.material, fixture.params)!!;
    check_pixel(centre(&fixture), BLUE);
    fixture.scene.remove(background);
    check_pixel(centre(&fixture), WHITE);
}

fn void test_particle_additive_sums_rgb_and_keeps_alpha() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    fixture.scene.background.color = { 0.1f, 0.1f, 0.1f, 0.4f };
    fixture.assets.material(fixture.material).data.common.blend_mode = BlendMode.ADDITIVE;
    fixture.assets.mark_material_dirty(fixture.material);
    ParticleSystemDesc desc = quiet_desc();
    desc.color_min = desc.color_max = { 0.2f, 0.1f, 0, 0.5f };
    Node* emitter = add_emitter(&fixture, desc);
    burst(&fixture, emitter);
    check_pixel(centre(&fixture), { 0.2f, 0.15f, 0.1f, 0.4f });
    burst(&fixture, emitter, 15);
    check_pixel(centre(&fixture), { 1.7f, 0.9f, 0.1f, 0.4f });
}

fn void test_particle_ambient_and_fog_use_generic_material_rules() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    fixture.scene.ambient_color = { 1, 1, 1 };
    fixture.scene.ambient_intensity = 0.25f;
    Node* emitter = add_emitter(&fixture, quiet_desc());
    burst(&fixture, emitter);
    check_pixel(centre(&fixture), WHITE);
    fixture.params.lighting = ParticleLighting.AMBIENT;
    fixture.assets.@set_custom_params(fixture.material, fixture.params)!!;
    check_pixel(centre(&fixture), { 0.25f, 0.25f, 0.25f, 1 });
    HeightFog fog = light::HEIGHT_FOG_DEFAULT;
    fog.density = 0.1f;
    fog.falloff = 0;
    fog.albedo = { 0.2f, 0.4f, 0.6f };
    Node* fog_node = fixture.scene.add_node()!!;
    fixture.scene.add(fog_node, fog);
    fixture.params.lighting = ParticleLighting.UNLIT;
    fixture.params.color = { 0, 0, 0, 1 };
    fixture.assets.@set_custom_params(fixture.material, fixture.params)!!;
    fixture.assets.material(fixture.material).data.common.blend_mode = BlendMode.ADDITIVE;
    fixture.assets.mark_material_dirty(fixture.material);
    Vec4 black_additive = centre(&fixture);
    emitter.visible = false;
    Vec4 background = centre(&fixture);
    check_pixel(black_additive, background);
    emitter.visible = true;
    fixture.params.color = WHITE;
    fixture.assets.@set_custom_params(fixture.material, fixture.params)!!;
    Vec4 white_additive = centre(&fixture);
    float transmittance = math::exp(-0.5f);
    for (uint channel = 0; channel < 3; channel++) {
        assert(math::abs(white_additive[channel] - background[channel] - transmittance) < PIXEL_TOLERANCE);
    }
    fixture.params.color = { 0, 0, 0, 1 };
    fixture.assets.@set_custom_params(fixture.material, fixture.params)!!;
    fixture.assets.material(fixture.material).data.common.blend_mode = BlendMode.PREMULTIPLIED_ALPHA;
    fixture.assets.mark_material_dirty(fixture.material);
    Vec4 black_alpha = centre(&fixture);
    for (uint channel = 0; channel < 3; channel++) {
        assert(math::abs(black_alpha[channel] - background[channel] * (1 - transmittance)) < PIXEL_TOLERANCE);
    }
}

fn void test_particle_stretch_tracks_projected_velocity() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    ParticleSystemDesc desc = quiet_desc();
    desc.render_mode = ParticleRenderMode.STRETCHED;
    desc.shape = EmitterShape.CONE;
    desc.radius = 0;
    desc.cone_angle = 0;
    desc.speed = { .min = 2, .max = 2 };
    desc.stretch = 0.5f;
    Node* emitter = add_emitter(&fixture, desc);
    emitter.local.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 2);
    burst(&fixture, emitter);
    render_frames(&fixture, true);
    Vec4[] front = read_pixels(&fixture);
    defer free(front);
    check_pixel(pixel_at(front, { 0.75f, 0 }), WHITE);
    check_pixel(pixel_at(front, { 0, 0.75f }), {});
    Vec4[] side = read_pixels(&fixture, 1);
    defer free(side);
    check_pixel(pixel_at(side, { 0.75f, 0 }), {});
    check_pixel(pixel_at(side, { 0, 0.75f }), WHITE);
    fixture.scene.remove(emitter);
    desc.stretch = 0;
    emitter = add_emitter(&fixture, desc);
    burst(&fixture, emitter);
    render_frames(&fixture);
    Vec4[] square = read_pixels(&fixture);
    defer free(square);
    check_pixel(pixel_at(square, { 0.75f, 0 }), {});
    check_pixel(pixel_at(square), WHITE);
}

fn void test_empty_hidden_and_removed_emitters_release_render_work() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Node* emitter = add_emitter(&fixture, quiet_desc());
    render_frames(&fixture);
    assert(fixture.renderer.stats.indirect_draws == 0 && fixture.renderer.stats.scene_snapshots == 0);
    burst(&fixture, emitter);
    check_pixel(centre(&fixture), WHITE);
    emitter.visible = false;
    fixture.scene.update_world();
    particle::update(&fixture.scene, 0.1f);
    assert(fixture.scene.get(emitter, ParticleSystem).age[0] == 0.1f);
    check_pixel(centre(&fixture), {});
    assert(fixture.renderer.stats.scene_snapshots == 0);
    emitter.visible = true;
    check_pixel(centre(&fixture), WHITE);
    Entity child = fixture.scene.get(emitter, ParticleSystem).draw_node;
    fixture.scene.remove(emitter);
    assert(!fixture.scene.world.is_alive(child));
    render_frames(&fixture, false, (uint)render::INSTANCE_ABSENCE_FRAMES + 1);
    assert(fixture.renderer.instances.lookup.len() == 0);
    assert(fixture.renderer.stats.indirect_draws == 0 && fixture.renderer.stats.scene_snapshots == 0);
}
