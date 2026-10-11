module c3d::test::transparency_desc;

import c3d;
import c3d::pool;
import c3d::render @public;

fn void test_transparency_view_defaults_preserve_sorted_mode() @test {
    ViewDesc window = render::default_view_desc();
    ViewDesc texture = render::texture_view_desc({ .index = 3, .generation = 7 });
    ViewDesc omitted;

    assert(window.transparency.mode == TransparencyMode.SORTED);
    assert(texture.transparency.mode == TransparencyMode.SORTED);
    assert(omitted.transparency.mode == TransparencyMode.SORTED);
}

fn void test_transparency_layered_default_has_four_valid_groups() @test {
    Renderer* renderer = mem::new(Renderer);
    defer free(renderer);

    ViewDesc desc = render::default_view_desc();
    desc.transparency = render::TRANSPARENCY_LAYERED_DEFAULT;
    assert(desc.transparency.mode == TransparencyMode.LAYERED);
    assert(desc.transparency.layer_capacity == 4);
    render::validate_view_desc(renderer, &desc)!!;
}

fn void test_transparency_layered_accepts_each_capacity_from_one_to_sixteen() @test {
    Renderer* renderer = mem::new(Renderer);
    defer free(renderer);

    ViewDesc desc = render::default_view_desc();
    desc.transparency.mode = TransparencyMode.LAYERED;
    for (uint capacity = 1; capacity <= 16; capacity++) {
        desc.transparency.layer_capacity = capacity;
        render::validate_view_desc(renderer, &desc)!!;
    }
}

fn void test_transparency_sorted_ignores_the_layer_capacity() @test {
    Renderer* renderer = mem::new(Renderer);
    defer free(renderer);

    ViewDesc desc = render::default_view_desc();
    uint[4] capacities = { 0, 4, 17, uint::max };
    foreach (capacity : capacities) {
        desc.transparency.layer_capacity = capacity;
        render::validate_view_desc(renderer, &desc)!!;
    }
}

fn void test_transparency_create_rejects_invalid_capacities_before_claiming_a_slot() @test {
    Renderer* renderer = mem::new(Renderer);
    defer free(renderer);
    renderer.views = pool::create_pool{ViewRecord, ViewId}(mem, 2);
    defer pool::destroy_pool{ViewRecord, ViewId}(&renderer.views);

    ViewDesc desc = render::default_view_desc();
    desc.transparency.mode = TransparencyMode.LAYERED;
    uint[3] capacities = { 0, 17, uint::max };
    foreach (capacity : capacities) {
        desc.transparency.layer_capacity = capacity;
        fault excuse = @catch(render::create_view(renderer, desc));
        assert(excuse == c3d::INVALID_ARGUMENT);
        assert(renderer.views.free_count == 2);
        foreach (generation : renderer.views.generations) assert(generation == 1);
        foreach (&record : renderer.views.items) assert(!record.live);
    }
}

fn void test_transparency_configure_rejects_invalid_capacities_without_changing_the_view() @test {
    Renderer* renderer = mem::new(Renderer);
    defer free(renderer);
    renderer.views = pool::create_pool{ViewRecord, ViewId}(mem, 2);
    defer pool::destroy_pool{ViewRecord, ViewId}(&renderer.views);

    ViewDesc original = render::default_view_desc();
    ViewId view = renderer.views.add({
        .live = true,
        .desc = original,
        .history = { .valid = true, .pending = true, .serial = 17 },
    })!!;
    ViewRecord* record = renderer.views.get(view);
    uint[3] capacities = { 0, 17, uint::max };
    foreach (capacity : capacities) {
        ViewDesc desc = original;
        desc.transparency = { .mode = TransparencyMode.LAYERED, .layer_capacity = capacity };
        fault excuse = @catch(render::configure_view(renderer, view, desc));
        assert(excuse == c3d::INVALID_ARGUMENT);
        assert(renderer.views.free_count == 1 && renderer.views.is_live(view));
        assert(record.desc.transparency.mode == original.transparency.mode);
        assert(record.desc.transparency.layer_capacity == original.transparency.layer_capacity);
        assert(record.history.valid && record.history.pending && record.history.serial == 17);
    }
}

fn void test_transparency_configure_preserves_the_stale_view_fault() @test {
    Renderer* renderer = mem::new(Renderer);
    defer free(renderer);
    renderer.views = pool::create_pool{ViewRecord, ViewId}(mem, 1);
    defer pool::destroy_pool{ViewRecord, ViewId}(&renderer.views);

    ViewId view = renderer.views.add({ .live = true, .desc = render::default_view_desc() })!!;
    renderer.views.remove(view);
    ViewDesc desc = render::default_view_desc();
    desc.transparency = { .mode = TransparencyMode.LAYERED };
    fault excuse = @catch(render::configure_view(renderer, view, desc));
    assert(excuse == c3d::INVALID_ID);
    assert(renderer.views.free_count == 1);
}
