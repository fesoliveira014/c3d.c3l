module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::material;
import c3d::render @public;
import c3d::scene;
import c3d::shader::compile;
import std::math;

const char[*] REFERENCE_FRAGMENT_SOURCE @private = $embed("reference.frag.glsl");
const Vec4 REFERENCE_EDITED_BASE_COLOR @private = { 0.2f, 0.5f, 0.9f, 1 };

fn ShaderId? add_reference_shader(Fixture* fixture) @private {
    @pool() {
        asset::ShaderDesc desc = {
            .fragment = compile::compile_glsl(tmem, (String)REFERENCE_FRAGMENT_SOURCE[..], ShaderStage.FRAGMENT)!,
        };
        return fixture.assets.add_shader(&desc);
    };
}

fn MaterialId? reference_material(Fixture* fixture, ShaderId shader, StandardParams params) @private {
    MaterialId layer = fixture.assets.add_material(material::standard(params))!;
    return fixture.assets.add_material(material::custom(shader, references: { [0] = layer }));
}

fn void check_reference_matches(Fixture* fixture, TwinScene* twin) @private {
    TwinReadings readings = render_twin_pair(fixture, twin, ShadingPath.FORWARD, LightSelection.FLAT)!!;
    defer {
        free(readings.standard);
        free(readings.twin);
    }
    check_twin_matches(readings, ShadingPath.FORWARD, LightSelection.FLAT);
    assert(fixture.renderer.stats.dangling_refs == 0);
}

fn void test_custom_stage_reads_a_referenced_standard_block() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    TwinScene twin = create_twin_scene(&fixture)!!;
    defer scene::destroy_scene(&twin.scene);
    ShaderId shader = add_reference_shader(&fixture)!!;
    twin.sphere_twin = reference_material(&fixture, shader, TWIN_SPHERE_PARAMS)!!;
    twin.ground_twin = reference_material(&fixture, shader, SHADOW_GROUND_PARAMS)!!;
    check_reference_matches(&fixture, &twin);

    MaterialId layer = fixture.assets.material(twin.sphere_twin).data.custom.references[0];
    uint custom_revision = fixture.assets.material(twin.sphere_twin).header.revision;
    MaterialId[2] edited = { twin.sphere_standard, layer };
    foreach (material_id : edited) {
        fixture.assets.material(material_id).data.standard.base_color = REFERENCE_EDITED_BASE_COLOR;
        fixture.assets.mark_material_dirty(material_id);
    }
    check_reference_matches(&fixture, &twin);
    assert(fixture.assets.material(twin.sphere_twin).header.revision == custom_revision);

    fixture.assets.remove_material(layer);
    // A current custom block holding the removed layer's address would read this live block.
    assert(fixture.assets.add_material(material::standard(TWIN_SPHERE_PARAMS))!!.index == layer.index);
    twin_use_materials(&twin, true);
    RenderTargetId target = render::create_render_target(
        renderer: &fixture.renderer,
        desc:     render::render_target_desc(TWIN_TARGET_SIZE, TWIN_TARGET_SIZE, PixelFormat.RGBA32_FLOAT),
    )!!;
    defer render::destroy_render_target(&fixture.renderer, target)!!;
    ViewId view = render::create_view(&fixture.renderer, render::texture_view_desc(target))!!;
    defer render::destroy_view(&fixture.renderer, view)!!;
    render_twin_frame(&fixture, &twin, view)!!;
    assert(fixture.renderer.stats.dangling_refs > 0);
    check_validation(&fixture.renderer);
}
