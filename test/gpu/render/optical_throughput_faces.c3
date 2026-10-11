module c3d::render::acceptance;

import c3d;
import c3d::render @public;
import gpu;
import std::io;
import std::math;

fn void check_optical_face_interiors(
    OpticalStack* stack,
    OpticalTraceResources* trace,
    bool blocked,
) @private {
    Vec4* atlas = (Vec4*)stack.output.bytes.ptr;
    Vec4* ray = (Vec4*)trace.output.bytes.ptr;
    for (uint row = 16; row < 48; row++) {
        for (uint column = 16; column < 48; column++) {
            uint pixel = row * OPTICAL_EXTENT + column;
            assert(bitcast(ray[pixel].w, uint) == bitcast(atlas[pixel].w, uint));
            for (uint channel = 0; channel < 3; channel++) {
                double reference = atlas[pixel][channel];
                double error = math::abs((double)ray[pixel][channel] - reference);
                double bound = OPTICAL_ABSOLUTE_TOLERANCE + OPTICAL_RELATIVE_TOLERANCE * math::abs(reference);
                assert(math::is_finite(ray[pixel][channel]) && error <= bound,
                    "Face interior pixel=%s channel=%s ray=%s atlas=%s", pixel, channel, ray[pixel][channel], reference);
                if (blocked) assert(ray[pixel][channel] == 0);
            }
        }
    }
}

fn void test_optical_throughput_single_reversed_and_mirrored_faces_preserve_authored_facing() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    assert(fixture.renderer.caps.ray_queries.enabled);
    OpticalStack stack;
    create_optical_stack(&fixture.renderer, &stack)!!;
    defer destroy_optical_stack(&fixture.renderer, &stack);
    foreach (flags : (uint[6]){
        OPTICAL_FACE_POLICY,
        OPTICAL_FACE_POLICY | OPTICAL_REVERSED,
        OPTICAL_FACE_POLICY | OPTICAL_MIRRORED,
        OPTICAL_FACE_POLICY | OPTICAL_REVERSED | OPTICAL_MIRRORED,
        OPTICAL_FACE_POLICY | OPTICAL_DOUBLE_SIDED | OPTICAL_REVERSED,
        OPTICAL_FACE_POLICY | OPTICAL_DOUBLE_SIDED | OPTICAL_REVERSED | OPTICAL_MIRRORED,
    }) {
        OpticalSurface[1] surfaces = { optical_default_surface() };
        surfaces[0].flags = OPTICAL_ALPHA_BLEND | flags;
        OpticalTraceResources trace;
        create_optical_trace(&fixture, &trace, surfaces[..])!!;
        defer destroy_optical_trace(&fixture, &trace);
        run_optical_stack(
            renderer: &fixture.renderer,
            stack: &stack,
            surfaces: surfaces[..],
            capacity: 1,
        )!!;
        check_optical_stack(&stack, surfaces[..], 1);
        foreach (hardware : (bool[2]){ false, true }) {
            run_optical_trace(
                fixture: &fixture,
                trace: &trace,
                surfaces: surfaces[..],
                capacity: 1,
                hardware: hardware,
            )!!;
            check_optical_face_interiors(&stack, &trace, false);
        }
        io::printfn("optical facing flags=%s visible=%s samples=1024 branches=atlas,hardware,software",
            flags, optical_survives(surfaces[0]));
    }
    check_validation(&fixture.renderer);
}

fn void test_optical_throughput_closed_double_sided_slab_counts_both_faces_and_keeps_beyond_cap_blockers() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    assert(fixture.renderer.caps.ray_queries.enabled);
    OpticalStack stack;
    create_optical_stack(&fixture.renderer, &stack)!!;
    defer destroy_optical_stack(&fixture.renderer, &stack);
    foreach (blocked : (bool[2]){ false, true }) {
        OpticalSurface[3] surfaces = {
            optical_default_surface(), optical_default_surface(), optical_default_surface(),
        };
        surfaces[0].model_scale.w = (9 - 4.0f) / 8;
        surfaces[0].flags |= OPTICAL_FACE_POLICY | OPTICAL_DOUBLE_SIDED;
        surfaces[0].node_index = 1;
        surfaces[1].model_scale.w = (9 - 4.25f) / 8;
        surfaces[1].flags |= OPTICAL_FACE_POLICY | OPTICAL_DOUBLE_SIDED | OPTICAL_REVERSED;
        surfaces[1].node_index = 2;
        surfaces[2].model_scale.w = (9 - 8.25f) / 8;
        surfaces[2].flags = OPTICAL_OPAQUE | OPTICAL_FACE_POLICY;
        surfaces[2].node_index = 3;
        uint count = blocked ? 3 : 2;
        OpticalTraceResources trace;
        create_optical_trace(&fixture, &trace, surfaces[:count])!!;
        defer destroy_optical_trace(&fixture, &trace);
        foreach (capacity : (uint[2]){ 1, 2 }) {
            run_optical_stack(
                renderer: &fixture.renderer,
                stack: &stack,
                surfaces: surfaces[:count],
                capacity: capacity,
            )!!;
            check_optical_stack(&stack, surfaces[:count], capacity);
            foreach (hardware : (bool[2]){ false, true }) {
                run_optical_trace(
                    fixture: &fixture,
                    trace: &trace,
                    surfaces: surfaces[:count],
                    capacity: capacity,
                    hardware: hardware,
                )!!;
                check_optical_face_interiors(&stack, &trace, blocked || capacity < 2);
            }
            io::printfn("optical slab faces=2 cap=%s blocker=%s samples=1024 branches=atlas,hardware,software",
                capacity, blocked);
        }
    }
    check_validation(&fixture.renderer);
}

fn void test_optical_throughput_segment_limits_keep_late_blockers_and_reject_beyond_receiver() @test {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: true)!!;
    defer destroy_fixture(&fixture);
    assert(fixture.renderer.caps.ray_queries.enabled);
    OpticalStack stack;
    create_optical_stack(&fixture.renderer, &stack)!!;
    defer destroy_optical_stack(&fixture.renderer, &stack);
    foreach (groups : (uint[2]){ 6, 17 }) {
        foreach (distance : (float[3]){ 2.5f, 8.25f, 9 }) {
            OpticalSurface[OPTICAL_SURFACE_CAPACITY] surfaces;
            uint count = make_optical_stack_sheets(surfaces[..], groups);
            OpticalSurface blocker = optical_default_surface();
            blocker.model_scale.w = (9 - distance) / 8;
            blocker.flags = OPTICAL_OPAQUE;
            blocker.node_index = groups + 1;
            surfaces[count++] = blocker;
            OpticalTraceResources trace;
            create_optical_trace(&fixture, &trace, surfaces[:count])!!;
            defer destroy_optical_trace(&fixture, &trace);
            foreach (capacity : (uint[2]){ 1, 16 }) {
                run_optical_stack(
                    renderer: &fixture.renderer,
                    stack: &stack,
                    surfaces: surfaces[:count],
                    capacity: capacity,
                )!!;
                check_optical_stack(&stack, surfaces[:count], capacity);
                foreach (hardware : (bool[2]){ false, true }) {
                    run_optical_trace(
                        fixture: &fixture,
                        trace: &trace,
                        surfaces: surfaces[:count],
                        capacity: capacity,
                        hardware: hardware,
                    )!!;
                    check_optical_face_interiors(&stack, &trace, distance < 8.5f || groups > capacity);
                }
                io::printfn("optical finite segment groups=%s cap=%s blocker_distance=%s receiver=8.5",
                    groups, capacity, distance);
            }
        }
    }
    check_validation(&fixture.renderer);
}
