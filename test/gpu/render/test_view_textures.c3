module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::material;
import c3d::render @public;
import c3d::scene;
import c3d::shader::compile;
import std::math;

const char[*] VIEW_TEXTURE_FRAGMENT_SOURCE @private = $embed("view_texture.frag.glsl");
const Vec4 VIEW_TEXTURE_ABSENT_COLOR @private = BLUE; // mirrored as ABSENT_COLOR in view_texture.frag.glsl
const uint VIEW_TEXTURE_CONSUMERS @private = 3;
const uint VIEW_TEXTURE_POOL_SIZE @private = 16; // the fixture's views and targets, two producers and three consumers
const Vec3 BACKDROP_SCALE @private = { 20, 20, 1 }; // fills the view whatever the box's thickness
const uint OFFSET_VIEW_SLOT @private = 2; // a slot other than zero, to show the index selects the texture

struct ViewTextureScene @private {
    Scene      scene;
    Node*      camera;
    Node*      surface;
    MaterialId slot_zero;
    MaterialId slot_offset;
}

struct ConsumerView @private {
    RenderTargetId output;
    ViewId         view;
}

struct ViewProducer @private {
    Scene          scene;
    Node*          camera;
    RenderTargetId target;
    ViewId         view;
}

fn MaterialId? add_view_texture_material(Fixture* fixture, ShaderId shader, uint view_slot) @private {
    TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS] slots = material::CUSTOM_SLOTS_DEFAULT;
    slots[0] = material::view_texture_slot(view_slot);
    return fixture.assets.add_material(material::custom(shader, slots: slots));
}

fn ViewTextureScene? create_view_texture_scene(Fixture* fixture) @private {
    ViewTextureScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);

    ShaderId shader;
    @pool() {
        asset::ShaderDesc desc = {
            .fragment = compile::compile_glsl(
                tmem,
                (String)VIEW_TEXTURE_FRAGMENT_SOURCE[..],
                ShaderStage.FRAGMENT,
            )!,
        };
        shader = fixture.assets.add_shader(&desc)!;
    };
    result.slot_zero = add_view_texture_material(fixture, shader, 0)!;
    result.slot_offset = add_view_texture_material(fixture, shader, OFFSET_VIEW_SLOT)!;
    result.surface = result.scene.add_mesh(fixture.box, result.slot_zero)!;
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    result.camera.local.position = CAMERA_POSITION;
    result.scene.update_world();
    return result;
}

fn ConsumerView? create_consumer_view(Fixture* fixture) @private {
    RenderTargetId output = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(TARGET_SIZE, TARGET_SIZE),
    )!;
    defer catch render::destroy_render_target(&fixture.renderer, output)!!;
    ViewId view = render::create_view(&fixture.renderer, render::texture_view_desc(output))!;
    return { .output = output, .view = view };
}

fn void destroy_consumer_view(Fixture* fixture, ConsumerView* consumer) @private {
    render::destroy_view(&fixture.renderer, consumer.view)!!;
    render::destroy_render_target(&fixture.renderer, consumer.output)!!;
}

fn ViewProducer? create_view_producer(Fixture* fixture, Vec4 color) @private {
    ViewProducer result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);

    MaterialId unlit = fixture.assets.add_material(material::basic({ .color = color }))!;
    Node* backdrop = result.scene.add_mesh(fixture.box, unlit)!;
    backdrop.local.scale = BACKDROP_SCALE;
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    result.camera.local.position = CAMERA_POSITION;
    result.scene.update_world();
    result.target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(TARGET_SIZE, TARGET_SIZE),
    )!;
    defer catch render::destroy_render_target(&fixture.renderer, result.target)!!;
    result.view = render::create_view(&fixture.renderer, render::texture_view_desc(result.target))!;
    return result;
}

fn void destroy_view_producer(Fixture* fixture, ViewProducer* producer) @private {
    render::destroy_view(&fixture.renderer, producer.view)!!;
    render::destroy_render_target(&fixture.renderer, producer.target)!!;
    scene::destroy_scene(&producer.scene);
}

fn void? render_producers_then_consumers(
    Fixture* fixture,
    ViewTextureScene* target,
    ViewProducer[] producers,
    ConsumerView[] consumers,
) @private {
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    foreach (&producer : producers) {
        renderer.render_view(&producer.scene, producer.camera, producer.view)!;
        renderer.finish_view(producer.view)!;
    }
    foreach (consumer : consumers) {
        renderer.render_view(&target.scene, target.camera, consumer.view)!;
        renderer.finish_view(consumer.view)!;
    }
    return renderer.end_frame();
}

fn uint? consumer_pixel(Fixture* fixture, ConsumerView* consumer) @private {
    sample_frame(fixture, render::read_target(consumer.output))!;
    return read_pixel(fixture);
}

fn void test_view_texture_shows_each_views_own_target_and_a_view_without_one_reads_absent() @test {
    Fixture fixture;
    create_fixture(
        allocator:          mem,
        fixture:            &fixture,
        max_views:          VIEW_TEXTURE_POOL_SIZE,
        max_render_targets: VIEW_TEXTURE_POOL_SIZE,
    )!!;
    defer destroy_fixture(&fixture);
    print_adapter(&fixture);
    ViewTextureScene target = create_view_texture_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);

    ViewProducer[2] producers = {
        create_view_producer(&fixture, RED)!!,
        create_view_producer(&fixture, GREEN)!!,
    };
    defer foreach (&producer : producers) destroy_view_producer(&fixture, producer);
    ConsumerView[VIEW_TEXTURE_CONSUMERS] consumers;
    foreach (&consumer : consumers) *consumer = create_consumer_view(&fixture)!!;
    defer foreach (&consumer : consumers) destroy_consumer_view(&fixture, consumer);

    fixture.renderer.set_view_texture(consumers[0].view, 0, producers[0].target)!!;
    fixture.renderer.set_view_texture(consumers[1].view, 0, producers[1].target)!!;
    render_producers_then_consumers(&fixture, &target, producers[..], consumers[..])!!;

    check_channels(consumer_pixel(&fixture, &consumers[0])!!, RED);
    check_channels(consumer_pixel(&fixture, &consumers[1])!!, GREEN);
    check_channels(consumer_pixel(&fixture, &consumers[2])!!, VIEW_TEXTURE_ABSENT_COLOR);
    check_validation(&fixture.renderer);
}

fn void test_view_texture_follows_its_slot_clear_target_and_view_lifetime() @test {
    Fixture fixture;
    create_fixture(
        allocator:          mem,
        fixture:            &fixture,
        max_views:          VIEW_TEXTURE_POOL_SIZE,
        max_render_targets: VIEW_TEXTURE_POOL_SIZE,
    )!!;
    defer destroy_fixture(&fixture);
    ViewTextureScene target = create_view_texture_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    ViewProducer[2] producers = {
        create_view_producer(&fixture, RED)!!,
        create_view_producer(&fixture, GREEN)!!,
    };
    defer destroy_view_producer(&fixture, &producers[1]);
    ConsumerView[1] consumers = { create_consumer_view(&fixture)!! };
    defer destroy_consumer_view(&fixture, &consumers[0]);
    Renderer* renderer = &fixture.renderer;

    renderer.set_view_texture(consumers[0].view, 0, producers[0].target)!!;
    renderer.set_view_texture(consumers[0].view, OFFSET_VIEW_SLOT, producers[1].target)!!;
    render_producers_then_consumers(&fixture, &target, producers[..], consumers[..])!!;
    check_channels(consumer_pixel(&fixture, &consumers[0])!!, RED);

    target.scene.get(target.surface, Mesh).material = target.slot_offset;
    render_producers_then_consumers(&fixture, &target, producers[..], consumers[..])!!;
    check_channels(consumer_pixel(&fixture, &consumers[0])!!, GREEN);

    target.scene.get(target.surface, Mesh).material = target.slot_zero;
    ViewDesc desc = renderer.views.get(consumers[0].view).desc;
    desc.lod_bias = 0.25f;
    render::configure_view(renderer, consumers[0].view, desc)!!;
    render_producers_then_consumers(&fixture, &target, producers[..], consumers[..])!!;
    check_channels(consumer_pixel(&fixture, &consumers[0])!!, RED);

    renderer.set_view_texture(consumers[0].view, 0, {})!!;
    render_producers_then_consumers(&fixture, &target, producers[..], consumers[..])!!;
    check_channels(consumer_pixel(&fixture, &consumers[0])!!, VIEW_TEXTURE_ABSENT_COLOR);

    renderer.set_view_texture(consumers[0].view, 0, producers[0].target)!!;
    destroy_view_producer(&fixture, &producers[0]);
    render_producers_then_consumers(&fixture, &target, producers[1:1], consumers[..])!!;
    check_channels(consumer_pixel(&fixture, &consumers[0])!!, VIEW_TEXTURE_ABSENT_COLOR);

    renderer.set_view_texture(consumers[0].view, 0, producers[1].target)!!;
    render::destroy_view(renderer, consumers[0].view)!!;
    consumers[0].view = render::create_view(renderer, render::texture_view_desc(consumers[0].output))!!;
    render_producers_then_consumers(&fixture, &target, producers[1:1], consumers[..])!!;
    check_channels(consumer_pixel(&fixture, &consumers[0])!!, VIEW_TEXTURE_ABSENT_COLOR);
    check_validation(renderer);
}

fn void test_view_texture_is_readied_for_sampling_before_the_view_records() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ViewTextureScene target = create_view_texture_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    ConsumerView[1] consumers = { create_consumer_view(&fixture)!! };
    defer destroy_consumer_view(&fixture, &consumers[0]);
    RenderTargetId unwritten = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(TARGET_SIZE, TARGET_SIZE),
    )!!;
    defer render::destroy_render_target(&fixture.renderer, unwritten)!!;

    Renderer* renderer = &fixture.renderer;
    assert(!render::same_texture_state(renderer.targets.get(unwritten).target.state, renderer.sampled_state));

    renderer.set_view_texture(consumers[0].view, 0, unwritten)!!;
    render_producers_then_consumers(&fixture, &target, {}, consumers[..])!!;
    assert(render::same_texture_state(renderer.targets.get(unwritten).target.state, renderer.sampled_state));
    check_validation(renderer);
}

fn void test_view_texture_reference_outside_a_custom_slot_or_range_faults_on_upload() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ViewTextureScene target = create_view_texture_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);

    MaterialId built_in = fixture.assets.add_material(material::basic({
        .color = { 1, 1, 1, 1 },
        .map = material::view_texture_slot(0),
    }))!!;
    if (catch excuse = fixture.renderer.upload_material(built_in)) {
        assert(excuse == c3d::UNSUPPORTED);
    } else {
        assert(false, "a built-in material accepted a view texture");
    }

    MaterialId out_of_range = target.slot_zero;
    fixture.assets.material(out_of_range).data.custom.slots[0].texture.view_slot = material::MAX_VIEW_TEXTURES;
    fixture.assets.mark_material_dirty(out_of_range);
    if (catch excuse = fixture.renderer.upload_material(out_of_range)) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "a custom material accepted a view slot past the last");
    }
}
