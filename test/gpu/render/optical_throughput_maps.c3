module c3d::render::acceptance;

import c3d;
import c3d::material;
import c3d::render @public;
import c3d::test::transparency_fixtures;
import gpu;
import std::io;
import std::math;

fn TextureId? add_optical_factor_map(Fixture* fixture) @private {
    Vec4[4] pixels;
    for (uint texel = 0; texel < pixels.len; texel++) {
        pixels[texel] = {
            (float)transparency_fixtures::TRANSMISSION_MAP[texel],
            (float)transparency_fixtures::THICKNESS_MAP[texel],
            0,
            (float)transparency_fixtures::COVERAGE_MAP[texel],
        };
    }
    material::TextureDesc desc = {
        .width = 2,
        .height = 2,
        .layers = 1,
        .mip_levels = 1,
        .format = PixelFormat.RGBA32_FLOAT,
        .debug_name = "optical_factor_map",
    };
    return fixture.assets.add_texture(desc, ((char*)&pixels)[:pixels.len * Vec4::size]);
}

fn OpticalSurface optical_mapped_reference(OpticalSurface surface, uint texel) @private {
    surface.factors.x *= (float)transparency_fixtures::TRANSMISSION_MAP[texel];
    surface.normal_thickness.w *= (float)transparency_fixtures::THICKNESS_MAP[texel];
    surface.base_coverage.w *= (float)transparency_fixtures::COVERAGE_MAP[texel];
    surface.map = 0;
    return surface;
}

fn void check_optical_map_pixel(Vec4 actual, OpticalSurface surface, uint texel, String branch) @private {
    OpticalSurface mapped = optical_mapped_reference(surface, texel);
    transparency_fixtures::Color expected = optical_expected_surface(mapped);
    bool scalar_blocker = optical_survives(mapped) && (mapped.flags & OPTICAL_ALPHA_BLEND) == 0;
    for (uint channel = 0; channel < 3; channel++) {
        double error = math::abs((double)actual[channel] - expected[channel]);
        double bound = OPTICAL_ABSOLUTE_TOLERANCE + OPTICAL_RELATIVE_TOLERANCE * math::abs(expected[channel]);
        assert(math::is_finite(actual[channel]) && error <= bound,
            "optical map branch=%s texel=%s channel=%s actual=%s expected=%s",
            branch, texel, channel, actual[channel], expected[channel]);
    }
    assert(bitcast(actual.w, uint) == bitcast(scalar_blocker ? 0.0f : 1.0f, uint));
}

fn void test_optical_throughput_nearest_factor_maps_and_mask_holes_match_atlas_hardware_and_software() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    assert(fixture.renderer.caps.ray_queries.enabled);
    Renderer* renderer = &fixture.renderer;
    TextureId texture = add_optical_factor_map(&fixture)!!;
    renderer.upload_texture(texture)!!;
    gpu::SamplerDesc sampler_desc = {
        .min_filter = gpu::Filter.NEAREST,
        .mag_filter = gpu::Filter.NEAREST,
        .mip_filter = gpu::Filter.NEAREST,
        .address_u = gpu::AddressMode.CLAMP_TO_EDGE,
        .address_v = gpu::AddressMode.CLAMP_TO_EDGE,
        .max_lod = 0,
        .debug_name = "optical_factor_nearest",
    };
    gpu::SamplerIndex sampler = gpu::intern_sampler(&renderer.device, &sampler_desc)!!;
    OpticalSurface[1] surfaces = { optical_default_surface() };
    surfaces[0].base_coverage.w = 1;
    surfaces[0].map = (uint)renderer.textures[texture.index].view.index;
    OpticalStack stack;
    create_optical_stack(renderer, &stack)!!;
    defer destroy_optical_stack(renderer, &stack);
    OpticalTraceResources trace;
    create_optical_trace(&fixture, &trace, surfaces[..])!!;
    defer destroy_optical_trace(&fixture, &trace);
    uint[4] columns = { 16, 40, 16, 40 };
    uint[4] rows = { 24, 24, 40, 40 };
    foreach (flags : (uint[3]){ OPTICAL_ALPHA_BLEND, OPTICAL_ALPHA_MASK, OPTICAL_ALPHA_BLEND | OPTICAL_ADDITIVE }) {
        surfaces[0].flags = flags;
        run_optical_stack(
            renderer: renderer,
            stack: &stack,
            surfaces: surfaces[..],
            capacity: 1,
            sampler: sampler,
        )!!;
        for (uint texel = 0; texel < 4; texel++) {
            uint pixel = rows[texel] * OPTICAL_EXTENT + columns[texel];
            check_optical_map_pixel(
                actual: ((Vec4*)stack.output.bytes.ptr)[pixel],
                surface: surfaces[0],
                texel: texel,
                branch: "atlas",
            );
            OpticalSurface mapped = optical_mapped_reference(surfaces[0], texel);
            float depth = optical_participates(mapped) ? mapped.model_scale.w : 0;
            uint captured = ((uint*)stack.readback.bytes.ptr)[pixel];
            uint shaded = ((uint*)(stack.readback.bytes.ptr + OPTICAL_SHADE_OFFSET))[pixel];
            assert(captured == bitcast(depth, uint) && shaded == captured);
            ushort* stored = (ushort*)(stack.readback.bytes.ptr + OPTICAL_PRODUCT_OFFSET);
            transparency_fixtures::Color expected = optical_expected_surface(mapped);
            for (uint channel = 0; channel < 3; channel++) {
                double error = math::abs(optical_half_value(stored[4 * pixel + channel]) - expected[channel]);
                double bound = OPTICAL_ABSOLUTE_TOLERANCE + OPTICAL_RELATIVE_TOLERANCE * math::abs(expected[channel]);
                assert(error <= bound, "Mapped stored-group throughput differs.");
            }
        }
        Vec4[4] atlas;
        Vec4[4] software;
        for (uint texel = 0; texel < 4; texel++) {
            uint pixel = rows[texel] * OPTICAL_EXTENT + columns[texel];
            atlas[texel] = ((Vec4*)stack.output.bytes.ptr)[pixel];
        }
        foreach (hardware : (bool[2]){ false, true }) {
            run_optical_trace(
                fixture: &fixture,
                trace: &trace,
                surfaces: surfaces[..],
                capacity: 1,
                hardware: hardware,
                sampler: sampler,
            )!!;
            for (uint texel = 0; texel < 4; texel++) {
                uint pixel = rows[texel] * OPTICAL_EXTENT + columns[texel];
                Vec4 actual = ((Vec4*)trace.output.bytes.ptr)[pixel];
                for (uint channel = 0; channel < 3; channel++) {
                    assert(math::abs((double)actual[channel] - atlas[texel][channel])
                      <= OPTICAL_BACKEND_DIFFERENCE_TOLERANCE);
                    if (hardware) {
                        assert(math::abs((double)actual[channel] - software[texel][channel])
                          <= OPTICAL_BACKEND_DIFFERENCE_TOLERANCE);
                    }
                }
                if (!hardware) software[texel] = actual;
                check_optical_map_pixel(
                    actual: actual,
                    surface: surfaces[0],
                    texel: texel,
                    branch: hardware ? "hardware" : "software",
                );
            }
        }
    }
    io::printfn("optical maps=2x2 channels=transmission:R,thickness:G,coverage:A texels=4 modes=OVER,MASK,ADDITIVE");
    check_validation(renderer);
}
