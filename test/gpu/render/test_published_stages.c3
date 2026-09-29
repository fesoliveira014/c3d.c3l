module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader::compile;
import gpu;

const char[*] PUBLISHED_SHIFTED_SOURCE @private = $embed("shifted.vert.glsl");

struct PublishedScene @private {
    DeformedScene target;
    ShaderId      shader;
    MaterialId    material;
}

fn char[]? published_shifted_stage(Fixture* fixture, String[] defines = {}) @private {
    return compile::compile_glsl(
        allocator: fixture.allocator,
        source:    (String)PUBLISHED_SHIFTED_SOURCE[..],
        stage:     ShaderStage.VERTEX,
        defines:   defines,
    );
}

fn char[]? published_broken_fragment(Fixture* fixture) @private {
    String[1] broken = { "BROKEN_PUSH" };
    return compile::compile_glsl(
        allocator: fixture.allocator,
        source:    (String)SCENE_PROBE_SOURCE[..],
        stage:     ShaderStage.FRAGMENT,
        defines:   broken[..],
    );
}

// The payload size matches the pulse shader's, so a material stays valid under either revision.
fn asset::ShaderDesc? published_shifted_desc(Fixture* fixture, bool broken_fragment) @private {
    String[1] depth_only = { "DEPTH_ONLY" };
    String[1] instanced = { "INSTANCED" };
    String[2] instanced_depth = { "DEPTH_ONLY", "INSTANCED" };
    return {
        .fragment = broken_fragment
          ? published_broken_fragment(fixture)!
          : compile_pulse_stage(fixture, PULSE_FRAGMENT, ShaderStage.FRAGMENT)!,
        .vertex   = {
            .shaded           = published_shifted_stage(fixture)!,
            .depth            = published_shifted_stage(fixture, depth_only[..])!,
            .instanced_shaded = published_shifted_stage(fixture, instanced[..])!,
            .instanced_depth  = published_shifted_stage(fixture, instanced_depth[..])!,
        },
        .param_block_size = PulseBlock::size,
    };
}

fn void? published_replace(Fixture* fixture, ShaderId shader, bool broken_fragment) @private {
    @pool() {
        asset::ShaderDesc desc = published_shifted_desc(fixture, broken_fragment)!;
        defer asset::free_shader_desc(fixture.allocator, &desc);
        fixture.assets.replace_shader(shader, &desc)!;
    };
    return;
}

fn PublishedScene? create_published_scene(Fixture* fixture) @private {
    PublishedScene result;
    @pool() {
        result.shader = add_pulse_shader(fixture)!;
    };
    PulseBlock still = { .color = { 1, 1, 1, 1 } };
    result.material = fixture.assets.add_material(material::custom(result.shader, material::@as_bytes(still)))!;
    result.target = create_single_box_scene(
        fixture:  fixture,
        geometry: fixture.box,
        material: result.material,
        sunlit:   false,
    )!;
    result.target.scene.ambient_intensity = 1;
    return result;
}

fn uint? render_published_frames(Fixture* fixture, DeformedScene* target, ViewId view) @private {
    Renderer* renderer = &fixture.renderer;
    uint pixel;
    for (uint frame = 0; frame < SETTLE_FRAMES; frame++) {
        target.scene.update_world();
        renderer.begin_frame()!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(&target.scene, target.camera, view)!;
        sample(fixture, render::read_view_color(view))!;
        record_readback(fixture)!;
        renderer.finish_view(view)!;
        renderer.end_frame()!;
        pixel = read_pixel(fixture);
        assert(renderer.stats.shader_rejections == 0);
    }
    return pixel;
}

fn void test_new_view_after_a_rejection_draws_the_published_stages() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    PublishedScene published = create_published_scene(&fixture)!!;
    defer scene::destroy_scene(&published.target.scene);
    ViewDesc forward = render::texture_view_desc(fixture.hdr_target);
    forward.depth_prepass = false;
    render::configure_view(renderer, fixture.view, forward)!!;
    uint published_pixel = render_published_frames(&fixture, &published.target, fixture.view)!!;
    check_opaque_color(published_pixel);

    published_replace(&fixture, published.shader, broken_fragment: true)!!;
    assert(@catch(renderer.upload(published.shader)) == gpu::SHADER_INVALID);
    assert(renderer.stats.shader_rejections == 1);

    ViewDesc deferred = render::texture_view_desc(fixture.hdr_target);
    deferred.shading = ShadingPath.DEFERRED;
    render::configure_view(renderer, fixture.second_view, deferred)!!;
    uint deferred_pixel = render_published_frames(&fixture, &published.target, fixture.second_view)!!;
    check_near_pixel(deferred_pixel, published_pixel);
    check_validation(renderer);

    published_replace(&fixture, published.shader, broken_fragment: false)!!;
    renderer.upload(published.shader)!!;
    @pool() {
        assert(renderer.pipelines.keys_of(tmem, published.shader, 1).len == 0);
        assert(renderer.pipelines.keys_of(tmem, published.shader, 3).len > 0);
    };
    deferred_pixel = render_published_frames(&fixture, &published.target, fixture.second_view)!!;
    check_near_pixel(deferred_pixel, published_pixel);
    check_validation(renderer);
}

fn void test_new_batch_after_a_rejection_draws_without_a_second_rejection() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    PublishedScene published = create_published_scene(&fixture)!!;
    defer scene::destroy_scene(&published.target.scene);
    uint published_pixel = render_published_frames(&fixture, &published.target, fixture.view)!!;
    check_opaque_color(published_pixel);

    published_replace(&fixture, published.shader, broken_fragment: true)!!;
    assert(@catch(renderer.upload(published.shader)) == gpu::SHADER_INVALID);
    assert(renderer.stats.shader_rejections == 1);

    published.target.mesh.visible = false;
    Transform[1] origin = { maths::TRANSFORM_IDENTITY };
    published.target.scene.add_instanced_mesh(
        geometry:   fixture.box,
        material:   published.material,
        capacity:   1,
        transforms: origin[..],
    )!!;
    uint batch_pixel = render_published_frames(&fixture, &published.target, fixture.view)!!;
    check_near_pixel(batch_pixel, published_pixel);
    check_validation(renderer);
}

fn void test_prepare_scene_skips_a_batch_its_shader_cannot_instance() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ShaderId plain;
    @pool() {
        String[1] depth_only = { "DEPTH_ONLY" };
        asset::ShaderDesc desc = {
            .fragment = compile_pulse_stage(&fixture, PULSE_FRAGMENT, ShaderStage.FRAGMENT)!!,
            .vertex   = {
                .shaded = compile_pulse_stage(&fixture, PULSE_VERTEX, ShaderStage.VERTEX)!!,
                .depth  = compile_pulse_stage(
                    fixture:  &fixture,
                    relative: PULSE_VERTEX,
                    stage:    ShaderStage.VERTEX,
                    defines:  depth_only[..],
                )!!,
            },
            .param_block_size = PulseBlock::size,
        };
        defer asset::free_shader_desc(fixture.allocator, &desc);
        plain = fixture.assets.add_shader(&desc, "plain_pulse")!!;
    };
    PulseBlock still = { .color = { 1, 1, 1, 1 } };
    MaterialId custom = fixture.assets.add_material(material::custom(plain, material::@as_bytes(still)))!!;
    DeformedScene target = create_single_box_scene(
        fixture:  &fixture,
        geometry: fixture.box,
        material: fixture.plain,
        sunlit:   false,
    )!!;
    defer scene::destroy_scene(&target.scene);
    Transform[1] beside = { maths::TRANSFORM_IDENTITY };
    beside[0].position = { 1, 0, 0 };
    target.scene.add_instanced_mesh(
        geometry:   fixture.box,
        material:   custom,
        capacity:   1,
        transforms: beside[..],
    )!!;
    target.scene.update_world();

    renderer.prepare_scene(&target.scene)!!;
    render_scene_and_sample(&fixture, &target)!!;
    assert(renderer.stats.dangling_refs == 1);
    check_validation(renderer);
}
