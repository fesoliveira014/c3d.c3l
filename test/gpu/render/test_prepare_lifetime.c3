module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::render @public;
import c3d::test::loading_fixtures;
import gpu;

fn void test_prepare_end_submitted_and_ready_preserves_cached_mips_and_id_generation() @test {
    foreach (end_ready : (bool[2]){ false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture)!!;
        defer destroy_fixture(&fixture);
        Renderer* renderer = &fixture.renderer;
        @pool() {
            material::TextureDesc desc = material::texture_2d_desc(PREPARATION_TEST_WIDTH, PREPARATION_TEST_HEIGHT, RGBA8_UNORM);
            char[] pixels = loading_fixtures::preparation_texture_bytes(tmem, (usz)desc.width * desc.height * 4);
            TextureId texture = fixture.assets.add_texture(desc, pixels)!!;
            TextureId expected = fixture.assets.add_texture(desc, pixels)!!;
            renderer.upload_texture(expected)!!;
            render::wait_frames(renderer)!!;
            ModelId model = preparation_texture_model(&fixture, texture)!!;
            PrepareId original = renderer.begin_prepare_model(model)!!;
            renderer.begin_frame()!!;
            PrepareReport report = renderer.advance_prepares_within({})!!;
            assert(report.staged_bytes > 0);
            renderer.end_frame()!!;
            PrepareRecord* record = renderer.prepares.get(original);
            assert(record.state == PrepareState.SUBMITTED && record.units_done == record.units.len);
            gpu::CompletionPoint covering = record.last_submission;
            assert(covering.is_valid());
            gpu::TextureHandle published = renderer.textures[texture.index].texture;
            assert(published.is_valid());
            if (end_ready) {
                gpu::wait_completion(covering)!!;
                assert(renderer.prepare_progress(original).state == PrepareState.READY);
                assert(record.state == PrepareState.READY);
            }
            renderer.end_prepare(original)!!;
            assert(renderer.textures[texture.index].texture == published);
            assert(@catch(renderer.end_prepare(original)) == c3d::INVALID_ID);
            PrepareProgress stale = renderer.prepare_progress(original);
            assert(stale.state == PrepareState.FAILED && stale.failure == c3d::INVALID_ID);
            gpu::wait_completion(covering)!!;
            preparation_compare_mips(&fixture, texture, expected);

            PrepareId reused = renderer.begin_prepare_model(model)!!;
            assert(reused.index == original.index && reused.generation != original.generation);
            assert(@catch(renderer.end_prepare(original)) == c3d::INVALID_ID);
            assert(renderer.prepare_progress(original).failure == c3d::INVALID_ID);
            renderer.begin_frame()!!;
            PrepareReport warm = renderer.advance_prepares_within({})!!;
            assert(warm.staged_bytes == 0 && warm.pipelines == 0);
            renderer.end_frame()!!;
            render::wait_frames(renderer)!!;
            assert(renderer.prepare_progress(reused).state == PrepareState.READY);
            renderer.end_prepare(reused)!!;
            assert(renderer.textures[texture.index].texture == published);
            assert(@catch(renderer.end_prepare(reused)) == c3d::INVALID_ID);
            preparation_compare_mips(&fixture, texture, expected);
            check_validation(renderer);
        };
    }
}
