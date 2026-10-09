module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::render @public;
import c3d::test::loading_fixtures;

const uint PREPARE_BUDGET_DRAIN_WIDTH @private = 256;
const uint PREPARE_BUDGET_DRAIN_HEIGHT @private = 128;
const usz PREPARE_BUDGET_DRAIN_BYTES @private = 16; // below the complete chain, forcing initial tail residency

fn void test_prepare_full_reader_after_budget_disable_rebuilds_streamed_tail() @test {
    foreach (custom_reader : (bool[2]){ false, true }) {
        Fixture fixture;
        create_fixture(
            allocator: mem,
            fixture: &fixture,
            texture_budget_bytes: PREPARE_BUDGET_DRAIN_BYTES,
        )!!;
        defer destroy_fixture(&fixture);
        Renderer* renderer = &fixture.renderer;
        ContainerSampler sampler = preparation_resident_sampler(&fixture)!!;
        defer destroy_container_sampler(&fixture, &sampler);
        @pool() {
            material::TextureDesc desc = material::texture_2d_desc(
                width: PREPARE_BUDGET_DRAIN_WIDTH,
                height: PREPARE_BUDGET_DRAIN_HEIGHT,
                format: RGBA8_UNORM,
            );
            char[] pixels = loading_fixtures::preparation_texture_bytes(
                allocator: tmem,
                bytes: (usz)desc.width * desc.height * 4,
            );
            TextureId stepped = fixture.assets.add_texture(desc, pixels)!!;
            TextureId synchronous = fixture.assets.add_texture(desc, pixels)!!;
            renderer.upload_texture(stepped)!!;
            TextureResidency tail = renderer.texture_residency(stepped)!!;
            assert(tail.streamed && tail.resident_base > 0);
            ModelId model;
            if (custom_reader) {
                ShaderId shader = add_pulse_shader(&fixture)!!;
                model = preparation_initial_consumer(&fixture, stepped, shader)!!;
            } else {
                ToonParams params = material::TOON_PARAMS_DEFAULT;
                params.gradient_map = stepped;
                MaterialId material = fixture.assets.add_material(material::toon(params))!!;
                model = preparation_asset_model(
                    fixture: &fixture,
                    geometry: fixture.box,
                    material: material,
                    morphed: false,
                )!!;
            }
            renderer.begin_frame()!!;
            assert(renderer.residencies[stepped.index].resident_base == tail.resident_base);
            renderer.set_texture_budget(0);
            assert(renderer.residencies[stepped.index].resident_base > 0);
            PrepareId id = renderer.begin_prepare_model(model)!!;
            PrepareUnit* unit = preparation_texture_unit(renderer, id, stepped)!!;
            assert(unit.full_reader && unit.texture_base == 0);
            assert(!render::texture_prepare_current(renderer, stepped, true));
            PrepareReport report = renderer.advance_prepares_within({})!!;
            assert(report.reason == PrepareStopReason.NONE);
            PrepareProgress progress = renderer.prepare_progress(id);
            assert(progress.state != PrepareState.FAILED);
            assert(renderer.residencies[stepped.index].resident_base == 0);
            renderer.end_frame()!!;
            preparation_drain(renderer: renderer, id: id, limits: {});
            renderer.end_prepare(id)!!;
            TextureResidency full = renderer.texture_residency(stepped)!!;
            assert(full.full_reader && !full.streamed && full.resident_base == 0);
            uint mips = material::texture_mip_count(desc.width, desc.height);
            assert(renderer.textures[stepped.index].mip_count == mips);
            renderer.upload_texture(synchronous)!!;
            for (uint mip = 0; mip < mips; mip++) {
                @pool() {
                    uint[] actual = preparation_resident_sample(
                        fixture: &fixture,
                        sampler: &sampler,
                        texture: stepped,
                        relative_mip: mip,
                    )!!;
                    uint[] expected = preparation_resident_sample(
                        fixture: &fixture,
                        sampler: &sampler,
                        texture: synchronous,
                        relative_mip: mip,
                    )!!;
                    assert(actual == expected);
                };
            }
        };
        check_validation(renderer);
    }
}
