module c3d::render::acceptance;

import c3d;
import c3d::render @public;
import c3d::test::transparency_fixtures;
import gpu;
import std::io;
import std::math;

fn void test_optical_throughput_full_authored_factor_matrix_matches_cpu_on_atlas_hardware_and_software() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    assert(fixture.renderer.caps.ray_queries.enabled);
    OpticalSurface[OPTICAL_MATRIX_CAPACITY] surfaces;
    uint count = make_optical_surface_matrix(surfaces[..]);
    OpticalStack stack;
    create_optical_stack(&fixture.renderer, &stack)!!;
    defer destroy_optical_stack(&fixture.renderer, &stack);
    OpticalTraceResources trace;
    create_optical_trace(&fixture, &trace, surfaces[:count])!!;
    defer destroy_optical_trace(&fixture, &trace);
    run_optical_stack(
        renderer: &fixture.renderer,
        stack: &stack,
        surfaces: surfaces[:count],
        capacity: 1,
    )!!;
    Vec4[OPTICAL_MATRIX_CAPACITY] atlas;
    Vec4[OPTICAL_MATRIX_CAPACITY] software;
    double stored_error;
    for (uint index = 0; index < count; index++) {
        uint column = index % OPTICAL_TILE_COLUMNS * OPTICAL_TILE_WIDTH + OPTICAL_TILE_WIDTH / 2;
        uint row = index / OPTICAL_TILE_COLUMNS * OPTICAL_TILE_WIDTH + OPTICAL_TILE_WIDTH / 2;
        uint pixel = row * OPTICAL_EXTENT + column;
        atlas[index] = ((Vec4*)stack.output.bytes.ptr)[pixel];
        transparency_fixtures::Color expected = optical_expected_surface(surfaces[index]);
        bool scalar = optical_survives(surfaces[index]) && (surfaces[index].flags & OPTICAL_ALPHA_BLEND) == 0;
        assert(bitcast(atlas[index].w, uint) == bitcast(scalar ? 0.0f : 1.0f, uint));
        float depth = optical_participates(surfaces[index]) ? surfaces[index].model_scale.w : 0;
        uint captured = ((uint*)stack.readback.bytes.ptr)[pixel];
        uint shaded = ((uint*)(stack.readback.bytes.ptr + OPTICAL_SHADE_OFFSET))[pixel];
        assert(captured == bitcast(depth, uint) && shaded == captured);
        ushort* stored = (ushort*)(stack.readback.bytes.ptr + OPTICAL_PRODUCT_OFFSET);
        for (uint channel = 0; channel < 3; channel++) {
            double value = optical_half_value(stored[4 * pixel + channel]);
            double error = math::abs(value - expected[channel]);
            stored_error = math::max(stored_error, error);
            double bound = OPTICAL_ABSOLUTE_TOLERANCE + OPTICAL_RELATIVE_TOLERANCE * math::abs(expected[channel]);
            assert(math::is_finite(value) && error <= bound,
                "Matrix stored index=%s channel=%s actual=%s expected=%s", index, channel, value, expected[channel]);
            assert(math::abs((double)atlas[index][channel] - expected[channel]) <= bound);
        }
    }
    double pairwise_error;
    double full_precision_error;
    foreach (hardware : (bool[2]){ false, true }) {
        run_optical_trace(
            fixture: &fixture,
            trace: &trace,
            surfaces: surfaces[:count],
            capacity: 1,
            hardware: hardware,
        )!!;
        for (uint index = 0; index < count; index++) {
            uint column = index % OPTICAL_TILE_COLUMNS * OPTICAL_TILE_WIDTH + OPTICAL_TILE_WIDTH / 2;
            uint row = index / OPTICAL_TILE_COLUMNS * OPTICAL_TILE_WIDTH + OPTICAL_TILE_WIDTH / 2;
            Vec4 actual = ((Vec4*)trace.output.bytes.ptr)[row * OPTICAL_EXTENT + column];
            transparency_fixtures::Color expected = optical_expected_surface(surfaces[index]);
            assert(bitcast(actual.w, uint) == bitcast(atlas[index].w, uint));
            for (uint channel = 0; channel < 3; channel++) {
                double error = math::abs((double)actual[channel] - expected[channel]);
                full_precision_error = math::max(full_precision_error, error);
                double bound = OPTICAL_INTERMEDIATE_ABSOLUTE_TOLERANCE
                  + OPTICAL_INTERMEDIATE_RELATIVE_TOLERANCE * math::abs(expected[channel]);
                assert(math::is_finite(actual[channel]) && error <= bound,
                    "Matrix ray hardware=%s index=%s channel=%s actual=%s expected=%s",
                    hardware, index, channel, actual[channel], expected[channel]);
                double pair = math::abs((double)actual[channel] - atlas[index][channel]);
                pairwise_error = math::max(pairwise_error, pair);
                assert(pair <= OPTICAL_BACKEND_DIFFERENCE_TOLERANCE);
                if (hardware) {
                    pair = math::abs((double)actual[channel] - software[index][channel]);
                    pairwise_error = math::max(pairwise_error, pair);
                    assert(pair <= OPTICAL_BACKEND_DIFFERENCE_TOLERANCE);
                }
            }
            if (!hardware) software[index] = actual;
        }
    }
    io::printfn("optical authored matrix rows=%s stored_half_max_error=%s trace_float32_max_error=%s pairwise_max_error=%s",
        count, stored_error, full_precision_error, pairwise_error);
    check_validation(&fixture.renderer);
}
