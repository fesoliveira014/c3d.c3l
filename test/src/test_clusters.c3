module c3d::test::clusters;

import c3d;
import c3d::camera;
import c3d::light;
import c3d::maths;
import c3d::render;
import c3d::shader;
import std::math;

const float TOLERANCE @local = 0.0001f;
const Vec2 CELL_VIEWPORT @local = { 1280, 720 };
const Vec3 CELL_CAMERA_POSITION @local = { 0, 1, 5 };
const Vec3 CELL_CAMERA_FORWARD @local = { 0, -1, -5 };

struct CellFixture @local {
    ClusterDesc    desc;
    ClusterDepth   depth;
    CameraMatrices matrices;
    Vec3           forward;
}

fn CellFixture make_cell_fixture() @local {
    Camera camera = camera::perspective_deg(60, 0.1f);
    Transform pose = {
        .position = CELL_CAMERA_POSITION,
        .rotation = maths::look_rotation(CELL_CAMERA_FORWARD.normalize(), { 0, 1, 0 }),
        .scale    = { 1, 1, 1 },
    };
    ClusterDesc desc = render::default_cluster_desc();
    return {
        .desc     = desc,
        .depth    = render::cluster_depth(&camera, desc),
        .matrices = camera::derive_matrices(camera, pose.to_mat4(), CELL_VIEWPORT),
        .forward  = CELL_CAMERA_FORWARD.normalize(),
    };
}

fn float view_depth_of(CellFixture* fixture, Vec3 point) @local {
    return -fixture.matrices.view.apply({ point.x, point.y, point.z, 1 }).z;
}

fn void test_cluster_layout_aligns_regions() @test {
    ClusterDesc desc = {
        .tiles_x = 2, .tiles_y = 3, .depth_slices = 4,
        .lights_per_cluster = 5, .far_distance = 100,
    };
    ClusterLayout layout = render::cluster_layout(desc, 7, { 64, 64, 64 })!!;
    assert(layout.cluster_count == 24 && layout.index_count == 120);
    assert(layout.ranges_offset == 560 && layout.indices_offset == 752);
    assert(layout.counter_offset == 1232 && layout.size == 1248);

    desc = { .tiles_x = 1, .tiles_y = 1, .depth_slices = 1, .lights_per_cluster = 1, .far_distance = 100 };
    ClusterLayout padded = render::cluster_layout(desc, 1, { 64, 64, 64 })!!;
    assert(padded.cluster_count == 1 && padded.index_count == 1);
    assert(padded.ranges_offset == 80 && padded.indices_offset == 96);
    assert(padded.counter_offset == 112 && padded.size == 128);
    ClusterLayout[2] layouts = { layout, padded };
    uint[2] capacities = { 7, 1 };
    foreach (index, region : layouts) {
        assert(region.ranges_offset % render::STREAM_ALIGNMENT == 0);
        assert(region.indices_offset % render::STREAM_ALIGNMENT == 0);
        assert(region.counter_offset % render::STREAM_ALIGNMENT == 0);
        assert(region.size % render::STREAM_ALIGNMENT == 0);
        assert((usz)capacities[index] * LightGpu::size <= region.ranges_offset);
        assert(region.ranges_offset + (usz)region.cluster_count * ClusterRange::size <= region.indices_offset);
        assert(region.indices_offset + (usz)region.index_count * uint::size <= region.counter_offset);
        assert(region.counter_offset + ClusterCounterGpu::size <= region.size);
    }
}

fn void test_cluster_layout_rejects_invalid_numeric_configuration() @test {
    ClusterDesc valid = {
        .tiles_x = 2, .tiles_y = 3, .depth_slices = 4,
        .lights_per_cluster = 5, .far_distance = 100,
    };
    for (uint field = 0; field < 4; field++) {
        ClusterDesc desc = valid;
        switch (field) {
            case 0: desc.tiles_x = 0;
            case 1: desc.tiles_y = 0;
            case 2: desc.depth_slices = 0;
            case 3: desc.lights_per_cluster = 0;
        }
        if (catch excuse = render::cluster_layout(desc, 1, { uint::max, uint::max, uint::max })) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false, "Zero cluster dimension or capacity accepted");
        }
    }
    float[5] invalid_far = {
        0, -1, bitcast(0x7fc00000u, float), bitcast(0x7f800000u, float), bitcast(0xff800000u, float),
    };
    foreach (far_distance : invalid_far) {
        ClusterDesc desc = valid;
        desc.far_distance = far_distance;
        if (catch excuse = render::cluster_layout(desc, 1, { uint::max, uint::max, uint::max })) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false, "Invalid clustering distance accepted");
        }
    }
    ClusterDesc[2] overflowing = {
        { .tiles_x = uint::max, .tiles_y = 2, .depth_slices = 1, .lights_per_cluster = 1, .far_distance = 100 },
        { .tiles_x = 65536, .tiles_y = 1, .depth_slices = 1, .lights_per_cluster = 65536, .far_distance = 100 },
    };
    foreach (desc : overflowing) {
        if (catch excuse = render::cluster_layout(desc, 1, { uint::max, uint::max, uint::max })) {
            assert(excuse == c3d::INVALID_ARGUMENT);
        } else {
            assert(false, "Overflowing cluster product accepted");
        }
    }
}

fn void test_cluster_layout_rejects_unsupported_dispatch_dimensions() @test {
    ClusterDesc desc = {
        .tiles_x = 2, .tiles_y = 3, .depth_slices = 4,
        .lights_per_cluster = 5, .far_distance = 100,
    };
    assert(render::cluster_layout(desc, 7, { 2, 3, 4 })!!.cluster_count == 24);
    uint[<3>][3] limits = { { 1, 3, 4 }, { 2, 2, 4 }, { 2, 3, 3 } };
    foreach (limit : limits) {
        if (catch excuse = render::cluster_layout(desc, 7, limit)) {
            assert(excuse == c3d::UNSUPPORTED);
        } else {
            assert(false, "Unsupported dispatch dimension accepted");
        }
    }
    desc.tiles_x = 0;
    if (catch excuse = render::cluster_layout(desc, 7, {})) {
        assert(excuse == c3d::INVALID_ARGUMENT);
    } else {
        assert(false, "Invalid numeric shape accepted");
    }
}

fn void test_perspective_cluster_depth_is_finite_and_logarithmic() @test {
    Camera camera = camera::perspective_deg(60, 1);
    ClusterDesc desc = { .depth_slices = 4, .far_distance = 16 };
    ClusterDepth depth = render::cluster_depth(&camera, desc);
    assert(depth.near == 1 && depth.far == 16);
    assert(math::is_finite(depth.scale) && math::is_finite(depth.bias));
    assert(math::abs(depth.scale - 4 / math::ln(16.0f)) < TOLERANCE && depth.bias == 0);
    float[5] boundaries = { 1, 2, 4, 8, 16 };
    foreach (index, boundary : boundaries) {
        assert(math::abs(math::ln(boundary) * depth.scale + depth.bias - (float)index) < TOLERANCE);
        if (index == 4) continue;
        Vec2 bounds = render::cluster_slice_bounds(depth, (uint)index);
        assert(math::abs(bounds.x - boundary) < TOLERANCE);
        assert(math::abs(bounds.y - boundaries[index + 1]) < TOLERANCE);
    }
    camera.far = 8;
    assert(render::cluster_depth(&camera, desc).far == 8);
    camera.far = 32;
    assert(render::cluster_depth(&camera, desc).far == 16);
}

fn void test_orthographic_cluster_depth_is_linear_and_clipped() @test {
    Camera camera = camera::orthographic(10, -4, 12);
    ClusterDesc desc = { .depth_slices = 3, .far_distance = 20 };
    ClusterDepth depth = render::cluster_depth(&camera, desc);
    assert(depth.near == 0 && depth.far == 12);
    assert(math::abs(depth.scale - 0.25f) < TOLERANCE && depth.bias == 0);
    for (uint slice = 0; slice < 3; slice++) {
        Vec2 bounds = render::cluster_slice_bounds(depth, slice);
        assert(math::abs(bounds.x - (float)(4 * slice)) < TOLERANCE);
        assert(math::abs(bounds.y - (float)(4 * (slice + 1))) < TOLERANCE);
    }
    camera.near = 2;
    camera.far = 14;
    depth = render::cluster_depth(&camera, desc);
    assert(depth.near == 2 && depth.far == 14);
    assert(math::abs(depth.scale - 0.25f) < TOLERANCE && math::abs(depth.bias + 0.5f) < TOLERANCE);
    for (uint slice = 0; slice < 3; slice++) {
        Vec2 bounds = render::cluster_slice_bounds(depth, slice);
        assert(math::abs(bounds.x - (float)(2 + 4 * slice)) < TOLERANCE);
        assert(math::abs(bounds.y - (float)(2 + 4 * (slice + 1))) < TOLERANCE);
    }
    desc.far_distance = 10;
    assert(render::cluster_depth(&camera, desc).far == 10);
}

fn void test_empty_cluster_coverage_disables_mapping() @test {
    Camera camera = camera::perspective_deg(60, 20);
    ClusterDesc desc = { .depth_slices = 4, .far_distance = 10 };
    ClusterDepth depth = render::cluster_depth(&camera, desc);
    assert(depth.near == 20 && depth.far == 10 && depth.scale == 0 && depth.bias == 0);
    camera = camera::orthographic(10, -4, 0);
    depth = render::cluster_depth(&camera, desc);
    assert(depth.near == 0 && depth.far == 0 && depth.scale == 0 && depth.bias == 0);
}

fn void test_global_light_indices_preserve_order_and_shadow_mapping() @test {
    LightGpu[5] lights = {
        { .kind = (uint)LightKind.POINT.ordinal, .position_range = { 1, 2, 3, 4 }, .layers = 1, .shadow_first = 0, .shadow_count = 6 },
        { .kind = (uint)LightKind.DIRECTIONAL.ordinal, .direction_cos_outer = { 0, -1, 0, 0 }, .layers = 2, .shadow_first = 6, .shadow_count = 4 },
        { .kind = (uint)LightKind.SPOT.ordinal, .layers = 4, .shadow_first = 10, .shadow_count = 1 },
        { .kind = (uint)LightKind.POINT.ordinal, .layers = 8, .shadow_first = 11, .shadow_count = 6 },
        { .kind = (uint)LightKind.SPOT.ordinal, .position_range = { 2, 3, 4, 5 }, .layers = 16, .shadow_first = 17, .shadow_count = 1 },
    };
    foreach (&light : lights) {
        light.color_intensity = { 1, 1, 1, 1 };
        if (light.kind == (uint)LightKind.SPOT.ordinal) {
            light.direction_cos_outer = { 0, -1, 0, 0.5f };
            light.cos_inner = 0.75f;
        }
    }
    LightGpu[5] saved = lights;
    uint[5] indices = { uint::max, uint::max, uint::max, uint::max, uint::max };
    assert(render::pack_global_light_indices(lights[..], indices[..]) == 3);
    assert(indices[0] == 1 && indices[1] == 2 && indices[2] == 3);
    assert(indices[3] == uint::max && indices[4] == uint::max);
    assert(mem::equals(&lights, &saved, LightGpu::size * lights.len));

    uint[5] written = indices;
    LightGpu[2] finite = { lights[0], lights[4] };
    assert(render::pack_global_light_indices(finite[..], indices[..]) == 0);
    assert(mem::equals(&indices, &written, uint::size * indices.len));
    assert(render::pack_global_light_indices({}, indices[..]) == 0);
    assert(mem::equals(&indices, &written, uint::size * indices.len));
}

fn void test_cluster_cell_agrees_for_reconstructed_position() @test {
    CellFixture fixture = make_cell_fixture();
    Vec3[4] points = { { 0, 0, 0 }, { 1.5f, -0.5f, 2 }, { -2, 3, -4 }, { 0.3f, 0.2f, -20 } };
    foreach (point : points) {
        Vec4 clip = fixture.matrices.view_proj.apply({ point.x, point.y, point.z, 1 });
        Vec3 ndc = clip.xyz / clip.w;
        Vec2 uv = { ndc.x * 0.5f + 0.5f, 0.5f - ndc.y * 0.5f };
        Vec3 reconstructed = render::reconstruct_world_position(fixture.matrices.inv_view_proj, uv, ndc.z);

        ClusterCell forward = render::cluster_cell(
            desc:           fixture.desc,
            depth:          fixture.depth,
            view_proj:      fixture.matrices.view_proj,
            world_position: point,
            view_depth:     view_depth_of(&fixture, point),
        );
        ClusterCell resolved = render::cluster_cell(
            desc:           fixture.desc,
            depth:          fixture.depth,
            view_proj:      fixture.matrices.view_proj,
            world_position: reconstructed,
            view_depth:     view_depth_of(&fixture, reconstructed),
        );
        assert(forward.clustered && resolved.clustered);
        assert(forward.cell == resolved.cell);
        assert(render::cluster_index(fixture.desc, forward.cell) == render::cluster_index(fixture.desc, resolved.cell));
    }
}

fn void test_cluster_cell_slice_agrees_with_slice_bounds() @test {
    CellFixture fixture = make_cell_fixture();
    for (uint slice = 0; slice < fixture.depth.slices; slice++) {
        Vec2 bounds = render::cluster_slice_bounds(fixture.depth, slice);
        float middle = (bounds.x + bounds.y) * 0.5f;
        Vec3 point = CELL_CAMERA_POSITION + fixture.forward * middle;
        ClusterCell cell = render::cluster_cell(fixture.desc, fixture.depth, fixture.matrices.view_proj, point, middle);
        assert(cell.clustered && cell.cell.z == slice);
    }

    Vec3 nearest = CELL_CAMERA_POSITION + fixture.forward * fixture.depth.near;
    ClusterCell first = render::cluster_cell(fixture.desc, fixture.depth, fixture.matrices.view_proj, nearest, fixture.depth.near);
    assert(first.clustered && first.cell.z == 0);

    Vec3 farthest = CELL_CAMERA_POSITION + fixture.forward * fixture.depth.far;
    ClusterCell beyond = render::cluster_cell(fixture.desc, fixture.depth, fixture.matrices.view_proj, farthest, fixture.depth.far);
    assert(!beyond.clustered);
}

fn void test_cluster_cell_rejects_offscreen_and_behind() @test {
    CellFixture fixture = make_cell_fixture();
    Vec3 behind = CELL_CAMERA_POSITION - fixture.forward * 3;
    ClusterCell reversed = render::cluster_cell(fixture.desc, fixture.depth, fixture.matrices.view_proj, behind, view_depth_of(&fixture, behind));
    assert(!reversed.clustered);

    Vec3 right = fixture.forward.cross({ 0, 1, 0 }).normalize();
    Vec3 aside = CELL_CAMERA_POSITION + fixture.forward * 5 + right * 100;
    ClusterCell offscreen = render::cluster_cell(fixture.desc, fixture.depth, fixture.matrices.view_proj, aside, view_depth_of(&fixture, aside));
    assert(!offscreen.clustered);
}
