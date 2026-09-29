module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::render @public;
import gpu;

const char[*] FETCH_R16_SOURCE @private = $embed("fetch_r16.comp.glsl");

struct FetchRoot @private {
    gpu::GpuAddress output_address;
    int[2] texel;
}
$assert FetchRoot::size == 16;

fn uint? fetch_r16_texel(
    Fixture* fixture,
    ComputeShaderId shader,
    TextureId texture,
    int[2] texel,
) @private {
    Renderer* renderer = &fixture.renderer;
    FetchRoot root = { .output_address = renderer.buffer_address(fixture.output), .texel = texel };
    BufferId[1] writes = { fixture.output };
    DispatchTexture[1] textures = { render::read_texture(texture) };
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.dispatch({
        .shader = shader,
        .root = ((char*)&root)[:FetchRoot::size],
        .groups = { 1, 1, 1 },
        .writes = writes[..],
        .textures = textures[..],
    })!;
    record_readback(fixture)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn void test_r16_texture_keeps_sixteen_bits_on_the_device() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    ComputeShaderId shader = add_compute_shader(&fixture, (String)FETCH_R16_SOURCE[..])!!;

    ushort[4] texels = { 0, 1, 0x1234, 0xFFFF };
    material::TextureDesc desc = material::texture_2d_desc(
        width:      2,
        height:     2,
        format:     R16_UINT,
        debug_name: "acceptance_r16",
    );
    desc.generate_mips = false;
    TextureId texture = fixture.assets.add_texture(desc, ((char*)&texels)[:texels.len * ushort::size])!!;
    foreach (index, expected : texels) {
        uint fetched = fetch_r16_texel(
            fixture: &fixture,
            shader:  shader,
            texture: texture,
            texel:   { (int)index % 2, (int)index / 2 },
        )!!;
        assert(fetched == expected, "texel %d", index);
    }
    check_validation(&fixture.renderer);
}

fn void test_r16_texture_is_unsupported_where_built_in_stages_sample_it() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;

    ushort[4] texels;
    material::TextureDesc desc = material::texture_2d_desc(
        width:      2,
        height:     2,
        format:     R16_UINT,
        debug_name: "acceptance_r16_slot",
    );
    desc.generate_mips = false;
    TextureId heights = fixture.assets.add_texture(desc, ((char*)&texels)[:texels.len * ushort::size])!!;

    MaterialId basic = fixture.assets.add_material(material::basic({
        .color = { 1, 1, 1, 1 },
        .map = material::texture_slot(heights),
    }))!!;
    assert(@catch(renderer.upload_material(basic)) == c3d::UNSUPPORTED);
    ToonParams banded = material::TOON_PARAMS_DEFAULT;
    banded.gradient_map = heights;
    MaterialId toon = fixture.assets.add_material(material::toon(banded))!!;
    assert(@catch(renderer.upload_material(toon)) == c3d::UNSUPPORTED);

    ShaderId pulse;
    @pool() {
        pulse = add_pulse_shader(&fixture)!!;
    };
    PulseBlock still = { .color = { 1, 1, 1, 1 } };
    TextureSlot[material::MAX_CUSTOM_TEXTURE_SLOTS] slots = material::CUSTOM_SLOTS_DEFAULT;
    slots[0] = material::texture_slot(heights);
    MaterialId opaque = fixture.assets.add_material(material::custom(pulse, material::@as_bytes(still), slots))!!;
    renderer.upload_material(opaque)!!;

    MaterialCommon mask = material::MATERIAL_COMMON_DEFAULT;
    mask.alpha_mode = AlphaMode.MASK;
    MaterialId masked_first = fixture.assets.add_material(material::custom(
        shader:      pulse,
        param_block: material::@as_bytes(still),
        slots:       slots,
        common:      mask,
    ))!!;
    assert(@catch(renderer.upload_material(masked_first)) == c3d::UNSUPPORTED);
    slots[1] = slots[0];
    slots[0] = material::CUSTOM_SLOTS_DEFAULT[0];
    MaterialId masked_second = fixture.assets.add_material(material::custom(
        shader:      pulse,
        param_block: material::@as_bytes(still),
        slots:       slots,
        common:      mask,
    ))!!;
    renderer.upload_material(masked_second)!!;
    check_validation(renderer);
}
