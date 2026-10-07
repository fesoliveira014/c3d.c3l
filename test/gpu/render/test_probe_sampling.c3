module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::io;
import std::math;

const uint PROBE_DARKENING_UPDATES @private = 8;
const uint PROBE_DARKENING_RAYS @private = 128;
const uint PROBE_DARKENING_IMAGE_SIZE @private = 33; // the center texel lies exactly over the receiver origin
const Vec3 PROBE_DARKENING_HALF_EXTENTS @private = { 0.5f, 1, 0.5f };
const uint[<3>] PROBE_DARKENING_COUNTS @private = { 2, 3, 2 };
const Vec3 PROBE_DARKENING_SKY @private = { 0.5f, 0.5f, 0.5f };
const float PROBE_DARKENING_SETUP_TOLERANCE @private = 1e-6f;
const float PROBE_DARKENING_RELATIVE_TOLERANCE @private = 0.05f;
const float PROBE_FALLBACK_TOLERANCE @private = 1e-3f;
const Vec3 PROBE_EXCLUDED_BOX_SCALE @private = { 0.2f, 0.2f, 0.2f };

struct ProbeDarkeningScene @private {
    Scene scene;
    Node* camera;
    Node* volume;
    MaterialId material;
}

struct ProbeDarkeningSamples @private {
    Vec3[PROBE_DARKENING_UPDATES] colors;
    ulong[PROBE_DARKENING_UPDATES] frames;
}

fn ProbeDarkeningScene? probe_darkening_create_scene(Fixture* fixture, float grid_origin_y) @private {
    ProbeDarkeningScene result;
    result.scene = scene::create_scene(fixture.allocator, { .max_nodes = 16 });
    defer catch scene::destroy_scene(&result.scene);
    result.scene.ambient_intensity = 0;
    result.scene.background.color = { 0, 0, 0, 1 };
    result.scene.environment = fixture.assets.add_environment(light::solid_environment(
        PROBE_DARKENING_SKY,
        { .conversion_size = 32, .specular_size = 32 },
    ))!;
    result.scene.environment_intensity = 1;

    GeometryId geometry;
    @pool() {
        Geometry floor = geometry::plane(tmem, 10, 10);
        geometry = fixture.assets.add_geometry(&floor)!;
    };
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color = { 0.8f, 0.8f, 0.8f, 1 };
    params.metallic = 0;
    params.roughness = 1;
    result.material = fixture.assets.add_material(material::standard(params))!;
    result.scene.add_mesh(geometry, result.material)!;

    result.volume = result.scene.add_node()!;
    result.volume.local.position = { 0, grid_origin_y + PROBE_DARKENING_HALF_EXTENTS.y, 0 };
    ProbeVolume volume = light::probe_volume(
        PROBE_DARKENING_HALF_EXTENTS, PROBE_DARKENING_COUNTS, ProbeFill.SCENE);
    volume.update.rays_per_probe = PROBE_DARKENING_RAYS;
    volume.update.probes_per_frame = 0;
    volume.update.hysteresis = 0;
    result.scene.add(result.volume, volume);
    result.camera = result.scene.add_camera(camera::orthographic(2, 0.1f, 20))!;
    result.camera.local.position = { 0, 3, 0 };
    result.camera.local.rotation = maths::look_rotation({ 0, -1, 0 }, { 0, 0, -1 });
    result.scene.update_world();
    return result;
}

fn void probe_darkening_check_placement(ProbeDarkeningScene* target, bool clear_reference) @private {
    ProbeVolume* volume = target.scene.get(target.volume, ProbeVolume);
    Vec3 spacing = volume.spacing();
    assert(spacing == (Vec3){ 1, 1, 1 });
    Vec3 origin = volume.probe_position(target.volume.world_position(), {});
    Vec3 last = origin + (Vec3)(volume.counts - 1) * spacing;
    for (uint axis = 0; axis < 3; axis++) assert(origin[axis] <= 0 && last[axis] >= 0);

    Vec3 normal = { 0, 1, 0 };
    Vec3 view_direction = maths::transform_dir(target.camera.world, { 0, 0, 1 });
    assert((view_direction - normal).length() < PROBE_DARKENING_SETUP_TOLERANCE);
    Vec3 biased = normal * volume.normal_bias + view_direction * volume.view_bias;
    assert(math::abs(biased.y - 0.15f) < PROBE_DARKENING_SETUP_TOLERANCE);
    Vec3 grid = (biased - origin) / spacing;
    uint base_y = (uint)math::floor(grid.y);
    assert(base_y == (clear_reference ? 1u : 0u));
    float lower = origin.y + (float)base_y * spacing.y;
    float upper = lower + spacing.y;
    assert(math::abs(lower - (clear_reference ? 0.1f : -0.1f)) < PROBE_DARKENING_SETUP_TOLERANCE);
    assert(math::abs(upper - (clear_reference ? 1.1f : 0.9f)) < PROBE_DARKENING_SETUP_TOLERANCE);

}

fn void? probe_darkening_copy_center(
    Renderer* renderer,
    RenderTargetId target,
    gpu::GpuSpan destination,
) @private {
    Target* image = &renderer.targets.get(target).target;
    gpu::TextureState previous = image.state;
    image.transition(&renderer.commands, render::TRANSFER_SOURCE_STATE)!;
    gpu::TextureBufferCopyDesc copy = {
        .texture = image.texture,
        .dst = destination,
        .layer_count = 1,
        .x = PROBE_DARKENING_IMAGE_SIZE / 2,
        .y = PROBE_DARKENING_IMAGE_SIZE / 2,
        .width = 1,
        .height = 1,
        .depth = 1,
    };
    gpu::cmd_copy_texture_to_buffer(&renderer.commands, &copy)!;
    gpu::Barrier to_host = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &to_host)!;
    image.transition(&renderer.commands, previous)!;
}

fn ProbeDarkeningSamples? probe_darkening_run(
    bool ray_queries,
    ShadingPath shading,
    float grid_origin_y,
    bool clear_reference,
) @private {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: ray_queries)!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    assert(renderer.caps.ray_queries.enabled == ray_queries);
    print_adapter(&fixture);
    ProbeDarkeningScene target = probe_darkening_create_scene(&fixture, grid_origin_y)!;
    defer scene::destroy_scene(&target.scene);
    probe_darkening_check_placement(&target, clear_reference);

    RenderTargetId output = render::create_render_target(
        renderer: renderer,
        desc: render::render_target_desc(
            PROBE_DARKENING_IMAGE_SIZE, PROBE_DARKENING_IMAGE_SIZE, PixelFormat.RGBA32_FLOAT),
    )!;
    defer render::destroy_render_target(renderer, output)!!;
    ViewDesc desc = render::texture_view_desc(output, OutputMode.LINEAR_HDR);
    desc.shading = shading;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    ViewId view = render::create_view(renderer, desc)!;
    defer render::destroy_view(renderer, view)!!;
    ViewRecord* record = renderer.views.get(view);
    assert(record.desc.color == OutputMode.LINEAR_HDR && record.desc.shading == shading);
    assert(record.desc.post.anti_aliasing == AntiAliasing.NONE && !record.desc.post.auto_exposure);
    Material* material = &fixture.assets.material(target.material).data;
    assert(material.kind == MaterialKind.STANDARD);
    DrawList expected_list = shading == ShadingPath.DEFERRED ? DrawList.GBUFFER : DrawList.OPAQUE;
    assert(render::view_draw_list(material, shading) == expected_list);

    gpu::AllocationDesc readback_desc = {
        .size = Vec4::size,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "probe_darkening_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!;
    defer {
        render::wait_frames(renderer)!!;
        gpu::GpuAllocation allocation = readback.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }
    ProbeDarkeningSamples result;
    for (uint update = 0; update < PROBE_DARKENING_UPDATES; update++) {
        result.frames[update] = renderer.frame_index;
        assert(result.frames[update] == update);
        renderer.begin_frame()!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(&target.scene, target.camera, view)!;
        assert(renderer.stats.probe_updates == 1);
        assert(renderer.stats.probe_rays == 12 * PROBE_DARKENING_RAYS);
        assert(record.gbuffer[0].texture.is_valid() == (shading == ShadingPath.DEFERRED));
        usz[shader::PROBE_VOLUME_CAPACITY] order;
        Camera* camera = target.scene.get(target.camera, Camera);
        usz selected = render::order_view_probe_volumes(
            mirrors: &renderer.probe_volumes,
            scene: &target.scene,
            view_layers: camera.layers,
            order: &order,
        );
        assert(selected == 1);
        ProbeVolumeRes* mirror = &renderer.probe_volumes[order[0]];
        assert(mirror.scene == target.scene.identity && c3d::same_id(mirror.entity, target.volume.id));
        assert(mirror.fill.scene_swept && mirror.updated_frame == result.frames[update] + 1);
        renderer.finish_view(view)!;
        // Keep readback in the update frame so paired fixtures use consecutive identical rotations.
        probe_darkening_copy_center(renderer, output, readback.span)!;
        renderer.end_frame()!;
        render::wait_frames(renderer)!;
        gpu::invalidate_mapped_span(&renderer.device, readback.span)!;
        assert(renderer.frame_index == result.frames[update] + 1);
        Vec4 pixel = *((Vec4*)readback.bytes.ptr);
        result.colors[update] = pixel.xyz;
        foreach (channel : result.colors[update]) {
            assert(math::is_finite(channel));
            if (clear_reference) assert(channel > 0);
        }
    }
    check_validation(renderer);
    return result;
}

fn void probe_darkening_check(bool ray_queries, ShadingPath shading) @private {
    ProbeDarkeningSamples buried = probe_darkening_run(
        ray_queries: ray_queries,
        shading: shading,
        grid_origin_y: -0.1f,
        clear_reference: false,
    )!!;
    ProbeDarkeningSamples clear = probe_darkening_run(
        ray_queries: ray_queries,
        shading: shading,
        grid_origin_y: -0.9f,
        clear_reference: true,
    )!!;
    Vec3 buried_mean;
    Vec3 clear_mean;
    for (uint update = 0; update < PROBE_DARKENING_UPDATES; update++) {
        assert(buried.frames[update] == clear.frames[update]);
        buried_mean += buried.colors[update];
        clear_mean += clear.colors[update];
    }
    buried_mean /= (float)PROBE_DARKENING_UPDATES;
    clear_mean /= (float)PROBE_DARKENING_UPDATES;
    Vec3 relative = (clear_mean - buried_mean) / clear_mean;
    foreach (difference : relative) assert(math::abs(difference) <= PROBE_DARKENING_RELATIVE_TOLERANCE);
    io::printfn(
        "summary,%s,%s,updates,%d,buried_r,%.9f,buried_g,%.9f,buried_b,%.9f,"
        "clear_r,%.9f,clear_g,%.9f,clear_b,%.9f,relative_r,%.9f,relative_g,%.9f,relative_b,%.9f",
        ray_queries ? "ray_query" : "software",
        shading == ShadingPath.DEFERRED ? "deferred" : "forward",
        PROBE_DARKENING_UPDATES,
        buried_mean.r,
        buried_mean.g,
        buried_mean.b,
        clear_mean.r,
        clear_mean.g,
        clear_mean.b,
        relative.r,
        relative.g,
        relative.b,
    );
}

fn void test_probe_buried_layer_matches_clear_software_forward() @test {
    probe_darkening_check(false, ShadingPath.FORWARD);
}

fn void test_probe_buried_layer_matches_clear_software_deferred() @test {
    probe_darkening_check(false, ShadingPath.DEFERRED);
}

fn void test_probe_buried_layer_matches_clear_ray_query_forward() @test {
    probe_darkening_check(true, ShadingPath.FORWARD);
}

fn void test_probe_buried_layer_matches_clear_ray_query_deferred() @test {
    probe_darkening_check(true, ShadingPath.DEFERRED);
}

fn void? probe_all_excluded_fallback(bool ray_queries, ShadingPath shading, bool ambient_only) @private {
    Fixture fixture;
    create_fixture(mem, &fixture, ray_queries: ray_queries)!;
    defer destroy_fixture(&fixture);
    Renderer* renderer = &fixture.renderer;
    assert(renderer.caps.ray_queries.enabled == ray_queries);
    ProbeDarkeningScene target = probe_darkening_create_scene(&fixture, -0.1f)!;
    defer scene::destroy_scene(&target.scene);
    if (ambient_only) {
        target.scene.environment = {};
        target.scene.ambient_color = { 0.3f, 0.5f, 0.7f };
        target.scene.ambient_intensity = 1;
    }
    ProbeVolume volume = light::probe_volume({ 0.5f, 0.5f, 0.5f }, { 2, 2, 2 }, ProbeFill.SCENE);
    volume.update = { .rays_per_probe = PROBE_DARKENING_RAYS, .probes_per_frame = 0, .hysteresis = 0 };
    *target.scene.get(target.volume, ProbeVolume) = volume;
    target.volume.local.position = {};
    for (uint index = 0; index < 8; index++) {
        Node* box = target.scene.add_mesh(fixture.box, target.material)!;
        box.local.position = {
            index & 1 ? 0.5f : -0.5f,
            index & 2 ? 0.5f : -0.5f,
            index & 4 ? 0.5f : -0.5f,
        };
        box.local.scale = PROBE_EXCLUDED_BOX_SCALE;
    }
    target.scene.update_world();

    RenderTargetId output = render::create_render_target(
        renderer: renderer,
        desc: render::render_target_desc(
            PROBE_DARKENING_IMAGE_SIZE, PROBE_DARKENING_IMAGE_SIZE, PixelFormat.RGBA32_FLOAT),
    )!;
    defer render::destroy_render_target(renderer, output)!!;
    ViewDesc desc = render::texture_view_desc(output, OutputMode.LINEAR_HDR);
    desc.shading = shading;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    ViewId view = render::create_view(renderer, desc)!;
    defer render::destroy_view(renderer, view)!!;
    uint[<2>] extent = render::probe_atlas_extent(volume.counts, shader::PROBE_IRRADIANCE_CELL);
    usz texel_count = (usz)extent.x * extent.y;
    usz atlas_bytes = texel_count * PROBE_CLASSIFICATION_TEXEL_BYTES;
    ComputeShaderId readback_shader = add_compute_shader(&fixture, (String)PROBE_READBACK_SOURCE[..])!;
    BufferId readback_output = renderer.create_buffer({ .size = atlas_bytes, .debug_name = "probe_fallback_output" })!;
    defer renderer.destroy_buffer(readback_output)!!;
    gpu::AllocationDesc readback_desc = {
        .size = Vec4::size + atlas_bytes,
        .alignment = 16,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "probe_fallback_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!;
    defer {
        render::wait_frames(renderer)!!;
        gpu::GpuAllocation allocation = readback.span.allocation();
        gpu::free_allocation(&renderer.device, &allocation)!!;
    }
    Vec3[2] colors;
    for (uint phase = 0; phase < 2; phase++) {
        if (phase) target.scene.remove_component(target.volume, ProbeVolume);
        renderer.begin_frame()!;
        defer catch render::abort_frame(renderer);
        renderer.render_view(&target.scene, target.camera, view)!;
        assert(renderer.views.get(view).desc.shading == shading);
        assert(renderer.views.get(view).gbuffer[0].texture.is_valid() == (shading == ShadingPath.DEFERRED));
        if (phase == 0) {
            assert(renderer.stats.probe_updates == 1 && renderer.stats.probe_rays == 8 * PROBE_DARKENING_RAYS);
            ProbeVolumeRes* mirror = mirror_of(&fixture, &target.scene, target.volume);
            assert(mirror != null && mirror.fill.scene_swept);
            probe_classification_copy_region(
                fixture: &fixture,
                atlas: &mirror.irradiance,
                destination: readback.span.checked_subspan(Vec4::size, atlas_bytes)!,
                width: extent.x,
                height: extent.y,
                readback_shader: readback_shader,
                readback_output: readback_output,
            )!;
        } else {
            assert(renderer.stats.probe_updates == 0);
            assert(!mirror_of(&fixture, &target.scene, target.volume));
        }
        renderer.finish_view(view)!;
        probe_darkening_copy_center(renderer, output, readback.span.checked_subspan(0, Vec4::size)!)!;
        renderer.end_frame()!;
        render::wait_frames(renderer)!;
        gpu::invalidate_mapped_span(&renderer.device, readback.span)!;
        Vec4 pixel = *((Vec4*)readback.bytes.ptr);
        colors[phase] = pixel.xyz;
        foreach (channel : colors[phase]) assert(math::is_finite(channel) && channel > 0);
        if (phase == 0) {
            assert(probe_classification_uniform_class(readback, Vec4::size, texel_count)
              == (uint)shader::PROBE_CLASS_EXCLUDED);
        }
    }
    Vec3 difference = math::abs(colors[0] - colors[1]);
    foreach (channel : difference) assert(channel <= PROBE_FALLBACK_TOLERANCE);
    io::printfn(
        "probe fallback %s/%s/%s: excluded %s, removed %s",
        ray_queries ? "ray_query" : "software",
        shading == ShadingPath.DEFERRED ? "deferred" : "forward",
        ambient_only ? "ambient" : "environment",
        colors[0],
        colors[1],
    );
    check_validation(renderer);
}

fn void test_probe_all_excluded_cell_uses_global_diffuse() @test {
    foreach (ray_queries : TRACE_KINDS) {
        foreach (ShadingPath shading : { ShadingPath.FORWARD, ShadingPath.DEFERRED }) {
            foreach (bool ambient_only : { false, true }) {
                probe_all_excluded_fallback(ray_queries, shading, ambient_only)!!;
            }
        }
    }
}
