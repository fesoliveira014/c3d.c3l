module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import gpu;
import std::math;

const char[*] DISPLACE_GEOMETRY_SOURCE @private = $embed("displace_geometry.comp.glsl");
const char[*] FILL_WORDS_SOURCE @private = $embed("fill_words.comp.glsl");
const float WRITE_REACH @private = 64; // half the edge of the bounds every write declares
const float OFFSCREEN_OFFSET @private = 20;
const uint READBACK_WORDS @private = 16;
const uint READBACK_FRAMES @private = 6;

struct DisplaceGeometryRoot @private {
    gpu::GpuAddress positions;
    uint            count;
    float           offset_x;
    float           offset_y;
    float           offset_z;
}
$assert DisplaceGeometryRoot::size == 24;

struct FillWordsRoot @private {
    gpu::GpuAddress words;
    uint            count;
    uint            value;
}
$assert FillWordsRoot::size == 16;

fn void? displace_geometry(Fixture* fixture, GeometryId geometry, ComputeShaderId shader, Vec3 offset) @private {
    Renderer* renderer = &fixture.renderer;
    DisplaceGeometryRoot root = {
        .positions = renderer.geometry_stream_address(geometry, GeometryStream.POSITIONS)!,
        .count     = fixture.assets.geometry(geometry).vertex_count,
        .offset_x  = offset.x,
        .offset_y  = offset.y,
        .offset_z  = offset.z,
    };
    GeometryWrite[1] writes = {{
        .geometry     = geometry,
        .streams      = { .positions = true },
        .local_bounds = {
            .min = { -WRITE_REACH, -WRITE_REACH, -WRITE_REACH },
            .max = { WRITE_REACH, WRITE_REACH, WRITE_REACH },
        },
    }};
    return renderer.dispatch({
        .shader   = shader,
        .root     = ((char*)&root)[:DisplaceGeometryRoot::size],
        .groups   = { 1, 1, 1 },
        .geometry = writes[..],
    });
}

fn Vec4? render_displaced_frame(
    VertexScene* target,
    LodVelocityProbe* probe,
    ComputeShaderId shader,
    float offset_x,
) @private {
    Fixture* fixture = target.fixture;
    Renderer* renderer = &fixture.renderer;
    ViewId view = fixture.view;
    target.target.scene.update_world();
    renderer.begin_frame({ .time = 1, .delta = 1.0f / 60, .reference_position = target.reference })!;
    defer catch render::abort_frame(renderer);
    displace_geometry(fixture, target.geometry, shader, { offset_x, 0, 0 })!;
    renderer.render_view(&target.target.scene, target.target.camera, view)!;
    record_lod_target(fixture, probe, &renderer.views.get(view).velocity)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, probe.readback.span)!;
    return lod_velocity_pixel(probe.readback, CENTER_UV);
}

fn uint? sample_displaced_frame(
    VertexScene* target,
    ComputeShaderId shader,
    float offset_x,
    bool written = true,
) @private {
    Fixture* fixture = target.fixture;
    Renderer* renderer = &fixture.renderer;
    target.target.scene.update_world();
    renderer.begin_frame({ .time = 1, .delta = 1.0f / 60, .reference_position = target.reference })!;
    defer catch render::abort_frame(renderer);
    if (written) displace_geometry(fixture, target.geometry, shader, { offset_x, 0, 0 })!;
    renderer.render_view(&target.target.scene, target.target.camera, fixture.view)!;
    sample(fixture, render::read_view_color(fixture.view))!;
    record_readback(fixture)!;
    renderer.finish_view(fixture.view)!;
    renderer.end_frame()!;
    return read_pixel(fixture);
}

fn void test_geometry_write_moves_the_draw_and_reports_its_velocity() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    LodVelocityProbe probe = create_velocity_probe(&fixture)!!;
    defer free_lod_readback(renderer, probe.readback);
    VertexScene target = create_vertex_scene(&fixture)!!;
    defer scene::destroy_scene(&target.target.scene);
    configure_vertex_view(&fixture, fixture.view, ShadingPath.FORWARD)!!;
    ComputeShaderId shader = add_compute_shader(&fixture, (String)DISPLACE_GEOMETRY_SOURCE[..])!!;
    renderer.upload_geometry(target.geometry)!!;

    check_rejected(render_displaced_frame(&target, &probe, shader, 0)!!);
    check_still(render_displaced_frame(&target, &probe, shader, 0)!!);
    check_still(render_displaced_frame(&target, &probe, shader, 0)!!);

    Vec4 moved = render_displaced_frame(&target, &probe, shader, VERTEX_STEP)!!;
    check_step(moved, vertex_step_velocity(&target, VERTEX_STEP));
    assert(renderer.stats.upload_bytes == 0 && renderer.stats.vertex_history_bytes == 0);
    check_still(render_displaced_frame(&target, &probe, shader, 0)!!);

    uint home = sample_displaced_frame(&target, shader, 0)!!;
    uint away = sample_displaced_frame(&target, shader, OFFSCREEN_OFFSET)!!;
    assert(home != away);
    assert(fixture.assets.geometry(target.geometry).data.bounds.max.x == WRITE_REACH);

    fixture.assets.mark_geometry_dirty(target.geometry);
    assert(fixture.assets.geometry(target.geometry).data.bounds.max.x != WRITE_REACH);
    assert(sample_displaced_frame(&target, shader, 0, written: false)!! == home);
    check_validation(renderer);
}

fn void test_readback_returns_the_buffer_as_it_was_frames_in_flight_earlier() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    ComputeShaderId shader = add_compute_shader(&fixture, (String)FILL_WORDS_SOURCE[..])!!;
    BufferId buffer = renderer.create_buffer({
        .size       = READBACK_WORDS * uint::size,
        .usage      = BufferUsage.READBACK,
        .debug_name = "readback_words",
    })!!;
    BufferId private_buffer = renderer.create_buffer({
        .size       = READBACK_WORDS * uint::size,
        .debug_name = "private_words",
    })!!;

    for (uint frame = 0; frame < READBACK_FRAMES; frame++) {
        renderer.begin_frame()!!;
        char[]? bytes = renderer.read_buffer(buffer);
        if (frame < render::FRAMES_IN_FLIGHT) {
            assert(@catch(bytes) == render::NOT_READY);
        } else {
            uint[] words = ((uint*)bytes!!.ptr)[:READBACK_WORDS];
            assert(bytes!!.len == READBACK_WORDS * uint::size);
            foreach (word : words) assert(word == frame - render::FRAMES_IN_FLIGHT + 1);
        }
        assert(@catch(renderer.read_buffer(private_buffer)) == c3d::INVALID_ARGUMENT);

        FillWordsRoot root = {
            .words = renderer.buffer_address(buffer),
            .count = READBACK_WORDS,
            .value = frame + 1,
        };
        BufferId[1] writes = { buffer };
        renderer.dispatch({
            .shader = shader,
            .root   = ((char*)&root)[:FillWordsRoot::size],
            .groups = { 1, 1, 1 },
            .writes = writes[..],
        })!!;
        renderer.end_frame()!!;
    }
    check_validation(renderer);
}
