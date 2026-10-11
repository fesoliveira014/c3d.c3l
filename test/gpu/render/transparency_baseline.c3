module c3d::render::acceptance;

import c3d;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import std::io;
import std::io::file;
import std::math::vector;
import std::core::string;

fn void baseline_image(String directory, String name, Vec4[] pixels) @local {
    @pool() {
        String filename = string::tformat("%s/%s.rgba32f", directory, name);
        file::save(filename, ((char*)pixels.ptr)[:pixels.len * Vec4::size])!!;
        io::printfn("baseline %s pixels=%s bytes=%s", name, pixels.len, pixels.len * Vec4::size);
    };
}

fn void capture_transparency_baseline(String directory) @local {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    MaterialBlendScene target = create_material_blend_scene(&fixture)!!;
    defer scene::destroy_scene(&target.scene);
    MaterialBlendView view = create_material_blend_view(&fixture)!!;
    defer destroy_material_blend_view(&fixture, &view);
    MaterialId over = add_material_blend(&fixture, { 0.8f, 0.1f, 0.2f, 0.5f })!!;
    MaterialId additive = add_material_blend(&fixture, { 0.1f, 0.4f, 0.2f, 0.25f }, BlendMode.ADDITIVE)!!;
    add_material_blend_plane(&target, over, { 0, 0, -1 })!!;
    add_material_blend_plane(&target, additive, {})!!;

    foreach (shading : (ShadingPath[2]){ FORWARD, DEFERRED }) @pool() {
        ViewDesc desc = fixture.renderer.views.get(view.view).desc;
        desc.shading = shading;
        render::configure_view(&fixture.renderer, view.view, desc)!!;
        Vec4[] pixels = render_material_blend_pixels(&fixture, &target, &view)!!;
        defer free(pixels);
        baseline_image(directory, shading == FORWARD ? "sorted_forward" : "sorted_deferred", pixels);
    };

    PhysicalParams physical = material::PHYSICAL_PARAMS_DEFAULT;
    physical.standard.base_color = { 0.8f, 0.6f, 0.4f, 1 };
    physical.transmission = 1;
    physical.standard.roughness = 0;
    physical.thickness = 0.5f;
    physical.attenuation_color = { 0.5f, 0.7f, 0.9f };
    physical.attenuation_distance = 2;
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.double_sided = true;
    MaterialId glass = fixture.assets.add_material(material::physical(physical, common))!!;
    add_material_blend_plane(&target, glass, { 0, 0, 0.5f })!!;
    foreach (shading : (ShadingPath[2]){ FORWARD, DEFERRED }) @pool() {
        ViewDesc desc = fixture.renderer.views.get(view.view).desc;
        desc.shading = shading;
        render::configure_view(&fixture.renderer, view.view, desc)!!;
        Vec4[] pixels = render_material_blend_pixels(&fixture, &target, &view)!!;
        defer free(pixels);
        baseline_image(directory, shading == FORWARD ? "smooth_forward" : "smooth_deferred", pixels);
    };
    check_validation(&fixture.renderer);
}

fn void capture_shadow_baseline(String directory) @local {
    foreach (ray_queries : (bool[2]){ false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
        defer destroy_fixture(&fixture);
        ShadowScene target = create_shadow_scene(&fixture)!!;
        defer scene::destroy_scene(&target.scene);
        uint[16] values;
        PhysicalParams glass = material::PHYSICAL_PARAMS_DEFAULT;
        glass.transmission = 1;
        MaterialId transmitting = fixture.assets.add_material(material::physical(glass))!!;
        MaterialCommon cutout = material::MATERIAL_COMMON_DEFAULT;
        cutout.alpha_mode = AlphaMode.MASK;
        cutout.alpha_cutoff = 0.5f;
        MaterialId transmitting_mask = fixture.assets.add_material(material::physical(glass, cutout))!!;
        for (uint traced = 0; traced < 2; traced++) {
            set_ray_traced_shadows(&fixture, traced != 0)!!;
            Mesh* caster = target.scene.get(target.box, Mesh);
            caster.material = target.opaque;
            values[traced * 8] = render_and_sample(&fixture, &target, SHADOWED_POINT)!!;
            values[traced * 8 + 1] = render_and_sample(&fixture, &target, LIT_POINT)!!;
            caster.material = target.transparent;
            values[traced * 8 + 2] = render_and_sample(&fixture, &target, SHADOWED_POINT)!!;
            caster.material = target.opaque;
            caster.cast_shadow = false;
            values[traced * 8 + 3] = render_and_sample(&fixture, &target, SHADOWED_POINT)!!;
            caster.cast_shadow = true;
            caster.material = transmitting;
            values[traced * 8 + 4] = render_and_sample(&fixture, &target, SHADOWED_POINT)!!;
            values[traced * 8 + 5] = render_and_sample(&fixture, &target, LIT_POINT)!!;
            caster.material = transmitting_mask;
            values[traced * 8 + 6] = render_and_sample(&fixture, &target, SHADOWED_POINT)!!;
            values[traced * 8 + 7] = render_and_sample(&fixture, &target, LIT_POINT)!!;
        }
        @pool() {
            String filename = string::tformat("%s/shadow_%s.u32", directory, ray_queries ? "hardware" : "software");
            file::save(filename, ((char*)&values)[:values.len * uint::size])!!;
            io::printfn("baseline shadow queries=%s values=%s", ray_queries, values[..]);
        };
        check_validation(&fixture.renderer);
    }
}

fn int main(String[] args) {
    if (args.len != 2) {
        io::eprintn("Usage: transparency_baseline OUTPUT_DIRECTORY");
        return 1;
    }

    capture_transparency_baseline(args[1]);
    capture_shadow_baseline(args[1]);
    return 0;
}
