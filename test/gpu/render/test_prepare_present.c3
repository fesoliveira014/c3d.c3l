module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::platform @public;
import c3d::render @public;
import c3d::test::loading_fixtures;
import gpu;
import std::io;
import std::time::clock;

const uint PRESENT_PROBE_ATTEMPTS @private = 16;
const ulong PRESENT_PROBE_DEADLINE_NS @private = 10_000_000_000; // deadline checked between complete native resize attempts
const uint PRESENT_PROBE_WINDOW_SIZE @private = 256;
const uint PRESENT_PROBE_RESIZED_SIZE @private = 320;
const int PRESENT_PROBE_OUT_OF_DATE_RESULT @private = -1000001004; // vk::Result.ERROR_OUT_OF_DATE_KHR in the native diagnostic

fn DebugEntry? preparation_present_fault(Renderer* renderer, usz first) @private {
    usz after = renderer.log.written.load();
    if (after - first > render::DEBUG_LOG_ENTRIES) return c3d::CAPACITY_EXCEEDED~;
    for (usz sequence = first; sequence < after; sequence++) {
        DebugEntry entry = renderer.log.entries[sequence % render::DEBUG_LOG_ENTRIES];
        String operation = ((ZString)&entry.operation[0]).str_view();
        if (operation != "present") continue;
        io::eprintfn("present public_fault=%s", entry.public_fault);
        io::eprintfn("present native_result=%s", entry.validation_id_number);
        if (!entry.category.backend || !entry.has_fault) continue;
        if (entry.public_fault == gpu::SWAPCHAIN_OUT_OF_DATE
          && entry.validation_id_number == PRESENT_PROBE_OUT_OF_DATE_RESULT) return entry;
    }
    return NOT_FOUND~;
}

fn void test_prepare_resize_present_failure_preserves_successful_texture_submission() @test {
    platform::Window? opened = platform::create_window(platform::default_window_desc(
        "c3d presentation probe", PRESENT_PROBE_WINDOW_SIZE, PRESENT_PROBE_WINDOW_SIZE));
    if (catch excuse = opened) {
        io::eprintfn("INCONCLUSIVE: window creation failed: %s", excuse);
        assert(false, "INCONCLUSIVE: no live window for the presentation probe.");
    }
    platform::Window window = opened;
    defer platform::destroy_window(&window);
    Fixture fixture = { .allocator = mem, .assets = capacity_assets() };
    defer asset::destroy_asset_store(&fixture.assets);
    fixture.renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &fixture.assets,
        desc: { .validation = true, .application_name = "render_acceptance" },
    )!!;
    defer {
        render::wait_frames(&fixture.renderer)!!;
        check_validation(&fixture.renderer);
        render::destroy_renderer(&fixture.renderer);
    }
    Renderer* renderer = &fixture.renderer;
    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        fixture.box = fixture.assets.add_geometry(&box)!!;
    };
    material::TextureDesc desc = material::texture_2d_desc(PREPARATION_TEST_WIDTH, PREPARATION_TEST_HEIGHT, RGBA8_UNORM);
    TextureId stepped;
    TextureId synchronous;
    @pool() {
        char[] pixels = loading_fixtures::preparation_texture_bytes(tmem, (usz)desc.width * desc.height * 4);
        stepped = fixture.assets.add_texture(desc, pixels)!!;
        synchronous = fixture.assets.add_texture(desc, pixels)!!;
    };
    ModelId model = preparation_texture_model(&fixture, stepped)!!;
    ContainerSampler sampler = preparation_sampler(&fixture, desc.width, desc.height)!!;
    defer destroy_container_sampler(&fixture, &sampler);
    renderer.upload_texture(stepped)!!;
    render::wait_frames(renderer)!!;
    std::time::Clock started = clock::now();
    bool observed;
    bool compared_observed;
    uint attempted;
    for (uint attempt = 0; attempt < PRESENT_PROBE_ATTEMPTS; attempt++) {
        if ((ulong)started.to_now() >= PRESENT_PROBE_DEADLINE_NS) break;
        attempted++;
        @pool() {
            foreach (&pixel : fixture.assets.texture(stepped).pixels) *pixel ^= (char)(attempt + 1);
            foreach (&pixel : fixture.assets.texture(synchronous).pixels) *pixel ^= (char)(attempt + 1);
            fixture.assets.mark_texture_dirty(stepped);
            fixture.assets.mark_texture_dirty(synchronous);
            renderer.upload_texture(synchronous)!!;
            render::wait_frames(renderer)!!;
            if (!window.poll()) break;
            platform::sync_window(&window, renderer);
            PrepareId prepare = renderer.begin_prepare_model(model)!!;
            renderer.begin_frame()!!;
            if (!renderer.has_output) {
                renderer.end_frame()!!;
                renderer.end_prepare(prepare)!!;
                continue;
            }
            gpu::CompletionPoint before_submit = renderer.last_submission;
            gpu::TextureHandle old = renderer.textures[stepped.index].texture;
            PrepareReport recorded = renderer.advance_prepares_within({})!!;
            assert(recorded.staged_bytes > 0 && renderer.pending_prepare_installs.len() > 0);
            gpu::TextureHandle candidate = renderer.textures[stepped.index].texture;
            assert(candidate.is_valid() && candidate != old);
            usz first_diagnostic = renderer.log.written.load();
            uint size = attempt % 2 == 0 ? PRESENT_PROBE_RESIZED_SIZE : PRESENT_PROBE_WINDOW_SIZE;
            if (catch excuse = platform::resize_preparation_present_window(&window, size, size)) {
                render::abort_frame(renderer);
                renderer.end_prepare(prepare)!!;
                io::eprintfn("INCONCLUSIVE: native resize/sync failed: %s", excuse);
                break;
            }
            platform::sync_window(&window, renderer);
            fault ended = @catch(renderer.end_frame());
            gpu::CompletionPoint submitted = renderer.last_submission;
            assert(renderer.frame_submitted && submitted.is_valid() && submitted != before_submit);
            assert(renderer.pending_prepare_installs.len() == 0);
            assert(renderer.textures[stepped.index].texture == candidate);
            assert(renderer.textures[stepped.index].revision == fixture.assets.texture(stepped).header.revision);
            DebugEntry? present = preparation_present_fault(renderer, first_diagnostic);
            if (catch excuse = present) {
                if (excuse != NOT_FOUND) io::eprintfn("INCONCLUSIVE: present diagnostic capture failed: %s", excuse);
            }
            if (try entry = present) {
                observed = true;
                assert(!ended || ended == gpu::SWAPCHAIN_OUT_OF_DATE);
                io::eprintfn("PRESENT_FAILURE_OBSERVED attempt=%s", attempt + 1);
                io::eprintfn("submitted completion_payload=%s", submitted.payload);
                io::eprintfn("committed texture_revision=%s", renderer.textures[stepped.index].revision);
            } else if (ended) {
                io::eprintfn("INCONCLUSIVE: end_frame fault without matching present diagnostic: %s", ended);
            }
            render::wait_frames(renderer)!!;
            assert(renderer.last_submission == submitted);
            assert(renderer.prepare_progress(prepare).state == PrepareState.READY);
            renderer.end_prepare(prepare)!!;
            if (!window.poll()) break;
            platform::sync_window(&window, renderer);
            uint mips = material::texture_mip_count(desc.width, desc.height);
            for (uint mip = 0; mip < mips; mip++) {
                @pool() {
                    uint[] actual = container_sample_mip(
                        fixture: &fixture,
                        sampler: &sampler,
                        texture: stepped,
                        mip: mip,
                    )!!;
                    uint[] expected = container_sample_mip(
                        fixture: &fixture,
                        sampler: &sampler,
                        texture: synchronous,
                        mip: mip,
                    )!!;
                    assert(actual == expected);
                };
            }
            check_validation(renderer);
            if (observed) {
                compared_observed = true;
                break;
            }
        };
    }
    check_validation(renderer);
    io::eprintfn("presentation_probe_attempts=%s", attempted);
    if (!observed) io::eprintfn("INCONCLUSIVE: no native present ERROR_OUT_OF_DATE_KHR observed within the bounded probe.");
    assert(observed && compared_observed, "INCONCLUSIVE: native presentation failure and matching committed readback remain unproven.");
}
