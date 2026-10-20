module c3d_water_acceptance;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::landscape::water @public;
import c3d::landscape::water_gpu;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import std::math;

const float SPECTRAL_PATCH @local = 24; // metres: the tile; 9.4 cm per texel, the sea's peak wave 2 cells out
const Vec2 SPECTRAL_WIND @local = { 15, 0 }; // metres per second: a 0.8 m sea over a long fetch
const float CLAIMED_REACH @local = 5000; // metres each way: the plane claims a 10 km body, so the fetch lets a sea rise
const float OCEAN_EXTENT @local = 8192; // metres
const float OCEAN_CELL_SIZE @local = 1.25f; // metres between the finest vertices
const double[3] SPECTRAL_TIMES @local = { 0.5, 4.8, 65540.8 }; // the last is past the repeat period
const float SEAM_HEIGHT_TOLERANCE @local = 0.001f; // metres: two tiles of one field are the same field
const uint PLANE_SEGMENTS @local = 256;
const float OCEAN_MESH_ALLOWANCE @local = 0.05f; // metres: 1.25 m triangles under waves of 5 m and longer
const float RMS_SHARE @local = 1.25f; // of the standard deviation the bound spans
const float SPECTRAL_MINIMUM @local = 0.1f; // metres: the sea stands visibly off the rest plane
const uint SEAM_PIXELS @local = 64; // the readback's point capacity: a row of the view across the tile edge
const int SEAM_FIRST_COLUMN @local = 32;
const int FIELD_COLUMN_STEP @local = 4; // texels of the field image read across its diagonal
const int FIELD_ROW_STEP @local = 3;
const Vec2 CALMER_WIND @local = { 8, 0 };
const float BLEND_SECONDS @local = 2;
const double BLEND_START @local = 10;

fn void? evolve_fields(Fixture* fixture) @private {
    return water_gpu::update(&fixture.renderer, &fixture.scene, &fixture.assets);
}

// A flat plane around a point on the x axis that claims to reach far: the fetch of the sea follows its bounds.
fn GeometryId plane_at(Fixture* fixture, float centre) @local {
    GeometryId id;
    @pool() {
        Geometry plane = geometry::plane(tmem, TWIN_EXTENT, TWIN_EXTENT, PLANE_SEGMENTS, PLANE_SEGMENTS);
        foreach (&position : plane.positions) position.x += centre;
        plane.bounds = {
            .min = { centre - CLAIMED_REACH, 0, -CLAIMED_REACH },
            .max = { centre + CLAIMED_REACH, 0, CLAIMED_REACH },
        };
        id = fixture.assets.add_geometry(&plane)!!;
    };
    return id;
}

fn WaterDesc spectral_desc(GeometryId plane) @local {
    WaterDesc desc = surface_desc((Wave[]){}, TWIN_EXTENT, TWIN_CELL_SIZE);
    desc.wave_model = SPECTRAL;
    desc.geometry = plane;
    desc.spectrum.patch_size = SPECTRAL_PATCH;
    return desc;
}

fn WaterDesc spectral_ocean_desc() @local {
    WaterDesc desc = surface_desc((Wave[]){}, OCEAN_EXTENT, OCEAN_CELL_SIZE);
    desc.wave_model = SPECTRAL;
    desc.mode = OCEAN;
    desc.spectrum.patch_size = SPECTRAL_PATCH;
    return desc;
}

fn Node* add_sea(Fixture* fixture, WaterDesc desc, Vec3 position = {}) @local {
    Node* node = add_water_node(fixture, desc, position);
    water::set_sea_state(
        scene:              &fixture.scene,
        assets:             &fixture.assets,
        node:               node.id,
        wind_velocity:      SPECTRAL_WIND,
        transition_seconds: 0,
    )!!;
    update_water(fixture, 0);
    return node;
}

fn Node* add_overhead_camera(Fixture* fixture, float centre = 0) @local {
    return add_camera_node(
        fixture:     fixture,
        fov_degrees: TWIN_FOV_DEGREES,
        position:    TWIN_CAMERA_POSITION + (Vec3){ centre, 0, 0 },
        forward:     { 0, -1, 0 },
        up:          { 0, 0, -1 },
    );
}

fn int[<2>][TWIN_GRID * TWIN_GRID] sample_pixels() @local {
    int[<2>][TWIN_GRID * TWIN_GRID] pixels;
    int margin = (int)TWIN_SIZE / 10;
    foreach (index, &pixel : pixels) {
        int step = ((int)TWIN_SIZE - 2 * margin) / ((int)TWIN_GRID - 1);
        *pixel = { margin + (int)(index % TWIN_GRID) * step, margin + (int)(index / TWIN_GRID) * step };
    }
    return pixels;
}

// Drawn against twin over the fixed pixels. The twin is statistical: every point stays within the reported bound and
// the root mean square lands near the standard deviation the bound spans.
fn void check_spectral_twin(bool ocean) @local {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Node* water_node;
    if (ocean) {
        water_node = add_sea(&fixture, spectral_ocean_desc(), OCEAN_POSITION);
        fixture.scene.get(water_node, InstancedMesh).quadtree.split_pixels = OCEAN_SPLIT_PIXELS;
    } else {
        water_node = add_sea(&fixture, spectral_desc(plane_at(&fixture, 0)));
    }
    Node* camera_node = add_overhead_camera(&fixture);
    ViewId view = add_view(&fixture, TWIN_SIZE);
    CameraMatrices matrices = matrices_of(&fixture, camera_node, TWIN_SIZE);
    SurfaceView surface = water::surface_view(&fixture.scene, &fixture.assets, water_node.id)!!;
    float bound = fixture.scene.get(water_node, WaterRuntime).spectral_bound;
    float allowance = ocean ? OCEAN_MESH_ALLOWANCE : 0;

    int[<2>][TWIN_GRID * TWIN_GRID] pixels = sample_pixels();
    double squares;
    float surface_extent;
    usz samples;
    foreach (time : SPECTRAL_TIMES) {
        Vec4[] depths = render_and_read(
            fixture:  &fixture,
            viewing:  camera_node,
            view:     view,
            time:     time,
            pixels:   pixels[..],
            depth:    true,
        )!!;
        foreach (index, pixel : pixels) {
            Vec3 drawn = unproject(
                matrices: &matrices,
                pixel:    pixel,
                size:     TWIN_SIZE,
                depth:    depths[index].x,
            );
            float twin = water::sample_surface(
                view:    &surface,
                world_x: drawn.x,
                world_z: drawn.z,
                time:    time,
            )!!;
            float error = math::abs(drawn.y - twin);
            assert(error <= bound + allowance, "drawn %f, twin %f, bound %f at %f s", drawn.y, twin, bound, time);
            squares += (double)error * error;
            surface_extent = max(surface_extent, math::abs(twin));
            samples++;
        }
    }
    double rms = math::sqrt(squares / (double)samples);
    float expected_rms = RMS_SHARE * bound / water::SPECTRAL_BOUND_SIGMAS + allowance;
    assert(rms <= expected_rms, "rms %f against bound %f", rms, bound);
    assert(surface_extent >= SPECTRAL_MINIMUM, "the sea stayed flat: %f", surface_extent);
    check_validation(&fixture.renderer);
}

fn void test_spectral_surface_matches_the_twin_within_its_bound() @test {
    check_spectral_twin(false);
    check_spectral_twin(true);
}

// Heights the pixels along the middle row see of a sea over a plane centred at a point, with a camera over it.
fn float[SEAM_PIXELS] draw_row(Fixture* fixture, float centre, double time) @local {
    Node* water_node = add_sea(fixture, spectral_desc(plane_at(fixture, centre)));
    defer fixture.scene.remove(water_node);
    Node* camera_node = add_overhead_camera(fixture, centre);
    defer fixture.scene.remove(camera_node);
    ViewId view = add_view(fixture, TWIN_SIZE);
    CameraMatrices matrices = matrices_of(fixture, camera_node, TWIN_SIZE);

    int[<2>][SEAM_PIXELS] pixels;
    foreach (index, &pixel : pixels) *pixel = { SEAM_FIRST_COLUMN + (int)index, (int)TWIN_SIZE / 2 };
    Vec4[] depths = render_and_read(
        fixture:  fixture,
        viewing:  camera_node,
        view:     view,
        time:     time,
        pixels:   pixels[..],
        depth:    true,
    )!!;
    float[SEAM_PIXELS] heights;
    foreach (index, pixel : pixels) {
        heights[index] = unproject(
            matrices: &matrices,
            pixel:    pixel,
            size:     TWIN_SIZE,
            depth:    depths[index].x,
        ).y;
    }
    return heights;
}

fn void test_spectral_tiles_meet_at_the_patch_edge() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);

    // One patch further along x, the plane sees the same field: the row crosses a tile edge in both.
    float[SEAM_PIXELS] here = draw_row(&fixture, 0, SPECTRAL_TIMES[1]);
    float[SEAM_PIXELS] there = draw_row(&fixture, SPECTRAL_PATCH, SPECTRAL_TIMES[1]);
    float spread;
    foreach (index, height : here) {
        float difference = math::abs(height - there[index]);
        assert(difference <= SEAM_HEIGHT_TOLERANCE, "%f against %f at %d", height, there[index], index);
        spread = max(spread, math::abs(height - here[0]));
    }
    assert(spread >= SPECTRAL_MINIMUM, "the row stayed flat: %f", spread);
    check_validation(&fixture.renderer);
}

// A frame that evolves the fields, then the texels of the displacement or of the one before it.
fn Vec4[SEAM_PIXELS] read_field(Fixture* fixture, SpectralState* state, bool previous, double time) @local {
    update_water(fixture, time);
    Renderer* renderer = &fixture.renderer;
    renderer.begin_frame({ .time = time, .delta = (float)VELOCITY_STEP })!!;
    defer catch render::abort_frame(renderer);
    update_fields(fixture)!!;
    int[<2>][SEAM_PIXELS] texels;
    foreach (index, &texel : texels) *texel = { (int)index * FIELD_COLUMN_STEP, (int)index * FIELD_ROW_STEP };
    TextureId field = previous ? state.previous : state.displacement;
    record_readback(fixture, render::read_texture(field), texels[..])!!;
    renderer.end_frame()!!;
    Vec4[SEAM_PIXELS] values;
    values[..] = read_texels(fixture, SEAM_PIXELS)[:SEAM_PIXELS];
    return values;
}

fn void test_spectral_previous_field_is_the_last_frames_displacement() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Node* water_node = add_sea(&fixture, spectral_desc(plane_at(&fixture, 0)));
    SpectralState* state = fixture.scene.get(water_node, WaterRuntime).spectral;

    Vec4[SEAM_PIXELS] first = read_field(&fixture, state, false, SPECTRAL_TIMES[0]);
    Vec4[SEAM_PIXELS] kept = read_field(&fixture, state, true, SPECTRAL_TIMES[1]);
    Vec4[SEAM_PIXELS] second = read_field(&fixture, state, false, SPECTRAL_TIMES[2]);
    Vec4[SEAM_PIXELS] kept_again = read_field(&fixture, state, true, SPECTRAL_TIMES[0]);
    float moved;
    foreach (index, texel : first) {
        assert(kept[index] == texel, "the history is not the frame before at %d", index);
        assert(kept_again[index] == second[index], "the history is not the frame before at %d", index);
        moved = max(moved, math::abs(second[index].y - texel.y));
    }
    assert(moved >= SPECTRAL_MINIMUM / 2, "the field did not move: %f", moved);

    // On its first frame a field has no motion.
    Fixture other;
    create_fixture(&other)!!;
    defer destroy_fixture(&other);
    Node* other_node = add_sea(&other, spectral_desc(plane_at(&other, 0)));
    SpectralState* other_state = other.scene.get(other_node, WaterRuntime).spectral;
    Vec4[SEAM_PIXELS] unmoved = read_field(&other, other_state, true, SPECTRAL_TIMES[0]);
    foreach (index, texel : first) assert(unmoved[index] == texel, "the first frame moved at %d", index);
    check_validation(&fixture.renderer);
}

fn void test_spectral_blend_follows_the_twin() @test {
    Fixture fixture;
    create_fixture(&fixture)!!;
    defer destroy_fixture(&fixture);
    Node* water_node = add_sea(&fixture, spectral_desc(plane_at(&fixture, 0)));
    Node* camera_node = add_overhead_camera(&fixture);
    ViewId view = add_view(&fixture, TWIN_SIZE);
    CameraMatrices matrices = matrices_of(&fixture, camera_node, TWIN_SIZE);

    water::set_sea_state(
        scene:              &fixture.scene,
        assets:             &fixture.assets,
        node:               water_node.id,
        wind_velocity:      CALMER_WIND,
        transition_seconds: BLEND_SECONDS,
    )!!;
    update_water(&fixture, BLEND_START);
    update_water(&fixture, BLEND_START + BLEND_SECONDS / 2);
    SurfaceView surface = water::surface_view(&fixture.scene, &fixture.assets, water_node.id)!!;
    SpectralState* state = fixture.scene.get(water_node, WaterRuntime).spectral;
    float bound = fixture.scene.get(water_node, WaterRuntime).spectral_bound;
    assert(state.blend > 0.4f && state.blend < 0.6f, "the blend stands at %f", state.blend);

    int[<2>][TWIN_GRID * TWIN_GRID] pixels = sample_pixels();
    double time = BLEND_START + BLEND_SECONDS / 2;
    Vec4[] depths = render_and_read(
        fixture:  &fixture,
        viewing:  camera_node,
        view:     view,
        time:     time,
        pixels:   pixels[..],
        depth:    true,
    )!!;
    foreach (index, pixel : pixels) {
        Vec3 drawn = unproject(
            matrices: &matrices,
            pixel:    pixel,
            size:     TWIN_SIZE,
            depth:    depths[index].x,
        );
        float twin = water::sample_surface(
            view:    &surface,
            world_x: drawn.x,
            world_z: drawn.z,
            time:    time,
        )!!;
        assert(math::abs(drawn.y - twin) <= bound, "drawn %f, twin %f, bound %f", drawn.y, twin, bound);
    }
    check_validation(&fixture.renderer);
}

fn void test_spectral_trace_matches_the_drawn_surface() @test {
    Fixture fixture;
    create_fixture(&fixture, false)!!;
    defer destroy_fixture(&fixture);
    WaterDesc desc = spectral_desc(plane_at(&fixture, 0));
    desc.trace = true;
    add_sea(&fixture, desc);
    Node* camera_node = add_overhead_camera(&fixture);
    TraceProbe probe = create_trace_probe(&fixture, camera_node, false)!!;
    defer destroy_trace_probe(&fixture, &probe);

    foreach (time : SPECTRAL_TIMES) {
        trace_frame(&fixture, &probe, time)!!;
        assert(fixture.renderer.stats.trace_posed_instances == 1 && fixture.renderer.stats.trace_poses == 1);

        TraceAgreement agreement = trace_agreement(&fixture, &probe);
        assert(agreement.covered >= COVERAGE_MINIMUM && agreement.mismatch == 0);
        assert(agreement.worst <= SURFACE_TOLERANCE, "worst %f at %f s", agreement.worst, time);
    }
    check_validation(&fixture.renderer);
}
