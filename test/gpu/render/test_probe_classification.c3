module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::io;
import std::math;

const uint PROBE_CLASSIFICATION_ROTATIONS @private = 64; // checks classification stability across rotating ray sets
const usz PROBE_CLASSIFICATION_TEXEL_BYTES @private = Vec4::size;
const usz PROBE_CLASSIFICATION_CELL_TEXELS @private = shader::PROBE_IRRADIANCE_CELL * shader::PROBE_IRRADIANCE_CELL;
const float PROBE_CLASSIFICATION_WALL_HALF_EXTENT @private = 16; // approximates a half-space near the origin
const float PROBE_CLASSIFICATION_WALL_DISTANCE @private = 0.1f; // one tenth of the unit probe spacing
const Vec3 PROBE_CLASSIFICATION_HALF_EXTENTS @private = { 0.5f, 0.5f, 0.5f };
const Vec3 PROBE_CLASSIFICATION_REST_OFFSET @private = { 3, 0, 0 };

enum ProbeClassificationPlacement @private {
    CLOSED_BOX,
    OPEN,
    WALL_FRONT,
    WALL_BEHIND,
    POSED_BOX,
}

struct ProbeClassificationScene @private {
    Scene scene;
    Node* camera;
    Node* volume;
    Vec3 probe_position;
}

struct ProbeClassificationReading @private {
    ulong frame;
    uint back_faces;
    uint surfaces;
    uint misses;
    uint classification;
}

fn String probe_classification_name(ProbeClassificationPlacement placement) @private {
    switch (placement) {
        case CLOSED_BOX: return "closed_box";
        case OPEN: return "open_probe";
        case WALL_FRONT: return "thin_wall_front";
        case WALL_BEHIND: return "thin_wall_behind_diagnostic";
        case POSED_BOX: return "posed_closed_box";
    }
}

fn GeometryId? probe_classification_wall(Fixture* fixture) @private {
    float extent = PROBE_CLASSIFICATION_WALL_HALF_EXTENT;
    Vec3[4] positions = {
        { -extent, -extent, 0 }, { extent, -extent, 0 },
        { extent, extent, 0 }, { -extent, extent, 0 },
    };
    Vec3[4] normals = { { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 }, { 0, 0, 1 } };
    uint[6] indices = { 0, 1, 2, 0, 2, 3 };
    Geometry geometry = {
        .positions = positions[..],
        .normals = normals[..],
        .indices = indices[..],
    };
    geometry.finalize();
    return fixture.assets.add_geometry(&geometry);
}

fn void? probe_classification_posed_box(
    Fixture* fixture,
    Scene* scene,
    MaterialId material,
) @private {
    GeometryId geometry;
    @pool() {
        Geometry shape = geometry::box(tmem, 1, 1, 1);
        foreach (&position : shape.positions) *position += PROBE_CLASSIFICATION_REST_OFFSET;
        shape.joints = alloc::new_array(tmem, ushort[<4>], shape.positions.len);
        shape.weights = alloc::new_array(tmem, Vec4, shape.positions.len);
        foreach (&weight : shape.weights) *weight = { 1, 0, 0, 0 };
        shape.finalize();
        geometry = fixture.assets.add_geometry(&shape)!;
    };
    Node* joint = scene.add_node()!;
    joint.local.position = -PROBE_CLASSIFICATION_REST_OFFSET;
    Node* mesh = scene.add_mesh(geometry, material)!;
    Node*[] joints = alloc::new_array(scene.allocator, Node*, 1);
    joints[0] = joint;
    scene.add(mesh, (SkinBinding){ .skeleton = fixture.skeleton, .joints = joints });
}

fn ProbeClassificationScene? probe_classification_create_scene(
    Fixture* fixture,
    ProbeClassificationPlacement placement,
    uint rays,
) @private {
    ProbeClassificationScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    result.scene.ambient_color = { 1, 1, 1 };
    result.scene.ambient_intensity = 1;
    MaterialId surface = fixture.assets.add_material(material::standard({
        .base_color = { 0.5f, 0.5f, 0.5f, 1 },
        .roughness = 1,
    }))!;
    switch (placement) {
        case CLOSED_BOX:
            result.scene.add_mesh(fixture.box, surface)!;
        case OPEN:
            break;
        case WALL_FRONT:
        case WALL_BEHIND:
            result.scene.add_mesh(probe_classification_wall(fixture)!, surface)!;
            result.probe_position.z = placement == ProbeClassificationPlacement.WALL_FRONT
              ? PROBE_CLASSIFICATION_WALL_DISTANCE : -PROBE_CLASSIFICATION_WALL_DISTANCE;
        case POSED_BOX:
            probe_classification_posed_box(fixture, &result.scene, surface)!;
    }
    result.volume = result.scene.add_node()!;
    result.volume.local.position = result.probe_position + PROBE_CLASSIFICATION_HALF_EXTENTS;
    ProbeVolume volume = light::probe_volume(PROBE_CLASSIFICATION_HALF_EXTENTS, { 2, 2, 2 }, ProbeFill.SCENE);
    volume.update.rays_per_probe = rays;
    volume.update.probes_per_frame = 0;
    result.scene.add(result.volume, volume);
    result.camera = result.scene.add_camera(camera::orthographic(4, 0.1f, 20))!;
    result.camera.local.position = { 0, 0, 3 };
    result.scene.update_world();
    result.probe_position = volume.probe_position(result.volume.world_position(), {});
    return result;
}

fn void? probe_classification_copy_region(
    Fixture* fixture,
    Target* atlas,
    gpu::GpuSpan destination,
    uint width,
    uint height,
    ComputeShaderId readback_shader,
    BufferId readback_output,
) @private {
    Renderer* renderer = &fixture.renderer;
    ProbeReadbackRoot root = {
        .output_address = renderer.buffer_address(readback_output),
        .atlas = atlas.view.index,
        .width = width,
        .height = height,
    };
    BufferId[1] writes = { readback_output };
    renderer.dispatch({
        .shader = readback_shader,
        .root = ((char*)&root)[:ProbeReadbackRoot::size],
        .groups = { (width + PROBE_READBACK_GROUP - 1) / PROBE_READBACK_GROUP,
            (height + PROBE_READBACK_GROUP - 1) / PROBE_READBACK_GROUP, 1 },
        .writes = writes[..],
    })!;
    gpu::Barrier readable = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &readable)!;
    gpu::BufferCopyDesc copy = {
        .src = gpu::get_allocation_span(&renderer.device, renderer.buffers.get(readback_output).allocation)!,
        .dst = destination,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
}

fn uint probe_classification_uniform_class(gpu::MappedGpuSpan readback, usz offset, usz texel_count) @private {
    Vec4* pixels = (Vec4*)(readback.bytes.ptr + offset);
    float alpha = pixels[0].w;
    assert(math::is_finite(alpha) && alpha >= 0 && alpha <= (float)shader::PROBE_CLASS_ELIGIBLE + 1);
    assert(alpha == math::floor(alpha));
    for (usz index = 1; index < texel_count; index++) {
        assert(pixels[index].w == alpha);
    }
    return (uint)math::min(alpha, (float)shader::PROBE_CLASS_ELIGIBLE);
}

fn ProbeClassificationReading? probe_classification_read_update(
    Fixture* fixture,
    ProbeClassificationScene* target,
    gpu::MappedGpuSpan readback,
    uint rays,
    ComputeShaderId readback_shader,
    BufferId readback_output,
) @private {
    Renderer* renderer = &fixture.renderer;
    ProbeClassificationReading result = { .frame = renderer.frame_index };
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&target.scene, target.camera, fixture.view)!;
    assert(renderer.stats.probe_updates == 1 && renderer.stats.probe_rays == 8 * rays);

    // Copy before frame closure: a separate readback frame would skip a ray-set rotation.
    gpu::Barrier readable = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &readable)!;
    gpu::GpuSpan source = gpu::get_allocation_span(&renderer.device, renderer.probe_update.rays)!;
    usz ray_bytes = (usz)rays * RayResultGpu::size;
    gpu::BufferCopyDesc copy = {
        .src = source.checked_subspan(0, ray_bytes)!,
        .dst = readback.span.checked_subspan(0, ray_bytes)!,
    };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    ProbeVolumeRes* mirror = mirror_of(fixture, &target.scene, target.volume);
    assert(mirror != null);
    probe_classification_copy_region(
        fixture: fixture,
        atlas: &mirror.irradiance,
        destination: readback.span.checked_subspan(
            ray_bytes, PROBE_CLASSIFICATION_CELL_TEXELS * PROBE_CLASSIFICATION_TEXEL_BYTES)!,
        width: shader::PROBE_IRRADIANCE_CELL,
        height: shader::PROBE_IRRADIANCE_CELL,
        readback_shader: readback_shader,
        readback_output: readback_output,
    )!;
    gpu::Barrier host_read = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &host_read)!;
    renderer.finish_view(fixture.view)!;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, readback.span)!;
    assert(renderer.frame_index == result.frame + 1);

    result.classification = probe_classification_uniform_class(
        readback, ray_bytes, PROBE_CLASSIFICATION_CELL_TEXELS);
    foreach (ray : ((RayResultGpu*)readback.bytes.ptr)[:rays]) {
        float distance = ray.radiance_distance.w;
        assert(math::is_finite(distance));
        if (distance < 0) {
            result.back_faces++;
        } else if (distance == render::PROBE_RAY_FAR) {
            result.misses++;
        } else {
            result.surfaces++;
        }
    }
    return result;
}

fn void probe_classification_measure(ProbeClassificationPlacement placement) @private {
    String name = probe_classification_name(placement);
    bool excluded = placement != ProbeClassificationPlacement.OPEN
      && placement != ProbeClassificationPlacement.WALL_FRONT;
    uint expected = (uint)(excluded ? shader::PROBE_CLASS_EXCLUDED : shader::PROBE_CLASS_ELIGIBLE);
    uint[2] budgets = { 32, 128 };
    foreach (rays : budgets) {
        uint[PROBE_CLASSIFICATION_ROTATIONS] software_counts;
        ulong[PROBE_CLASSIFICATION_ROTATIONS] software_frames;
        uint[PROBE_CLASSIFICATION_ROTATIONS] software_classes;
        foreach (ray_queries : TRACE_KINDS) {
            Fixture fixture;
            create_fixture(mem, &fixture, ray_queries: ray_queries)!!;
            defer destroy_fixture(&fixture);
            assert(fixture.renderer.caps.ray_queries.enabled == ray_queries);
            print_adapter(&fixture);
            String backend = ray_queries ? "ray_query" : "software";
            ProbeClassificationScene target = probe_classification_create_scene(&fixture, placement, rays)!!;
            defer scene::destroy_scene(&target.scene);
            ComputeShaderId readback_shader = add_compute_shader(&fixture, (String)PROBE_READBACK_SOURCE[..])!!;
            BufferId readback_output = fixture.renderer.create_buffer({
                .size = PROBE_CLASSIFICATION_CELL_TEXELS * PROBE_CLASSIFICATION_TEXEL_BYTES,
                .debug_name = "probe_classification_output",
            })!!;
            defer fixture.renderer.destroy_buffer(readback_output)!!;
            gpu::AllocationDesc readback_desc = {
                .size = (usz)rays * RayResultGpu::size
                  + PROBE_CLASSIFICATION_CELL_TEXELS * PROBE_CLASSIFICATION_TEXEL_BYTES,
                .alignment = 16,
                .memory_class = gpu::MemoryClass.CPU_READ,
                .access = { .graphics },
                .debug_name = "probe_classification_measurement",
            };
            gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&fixture.renderer.device, &readback_desc)!!;
            defer {
                render::wait_frames(&fixture.renderer)!!;
                gpu::GpuAllocation allocation = readback.span.allocation();
                gpu::free_allocation(&fixture.renderer.device, &allocation)!!;
            }
            uint minimum = rays;
            uint maximum;
            uint total;
            uint previous;
            uint maximum_step;
            uint differing_rotations;
            uint largest_difference;
            for (uint rotation = 0; rotation < PROBE_CLASSIFICATION_ROTATIONS; rotation++) {
                ProbeClassificationReading reading = probe_classification_read_update(
                    fixture: &fixture,
                    target: &target,
                    readback: readback,
                    rays: rays,
                    readback_shader: readback_shader,
                    readback_output: readback_output,
                )!!;
                assert(reading.classification == expected);
                if (placement == ProbeClassificationPlacement.POSED_BOX) {
                    assert(fixture.renderer.stats.trace_posed_instances == 1);
                }
                minimum = math::min(minimum, reading.back_faces);
                maximum = math::max(maximum, reading.back_faces);
                total += reading.back_faces;
                if (rotation) {
                    uint step = (uint)math::abs((int)reading.back_faces - (int)previous);
                    maximum_step = math::max(maximum_step, step);
                }
                previous = reading.back_faces;
                if (ray_queries) {
                    assert(reading.frame == software_frames[rotation]);
                    assert(reading.classification == software_classes[rotation]);
                    uint difference = (uint)math::abs((int)reading.back_faces - (int)software_counts[rotation]);
                    differing_rotations += difference != 0 ? 1 : 0;
                    largest_difference = math::max(largest_difference, difference);
                } else {
                    software_counts[rotation] = reading.back_faces;
                    software_frames[rotation] = reading.frame;
                    software_classes[rotation] = reading.classification;
                }
            }
            io::printfn(
                "classification,%s,%s,rays,%d,rotations,%d,min,%.9f,max,%.9f,mean,%.9f,max_step,%.9f,state,%d",
                name,
                backend,
                rays,
                PROBE_CLASSIFICATION_ROTATIONS,
                (float)minimum / (float)rays,
                (float)maximum / (float)rays,
                (float)total / (float)(rays * PROBE_CLASSIFICATION_ROTATIONS),
                (float)maximum_step / (float)rays,
                expected,
            );
            if (ray_queries) {
                io::printfn(
                    "parity,%s,rays,%d,differing_rotations,%d,max_fraction_difference,%.9f",
                    name,
                    rays,
                    differing_rotations,
                    (float)largest_difference / (float)rays,
                );
            }
            check_validation(&fixture.renderer);
        }
    }
}

fn void test_probe_classification_excludes_closed_box() @test {
    probe_classification_measure(ProbeClassificationPlacement.CLOSED_BOX);
}

fn void test_probe_classification_keeps_open_probe() @test {
    probe_classification_measure(ProbeClassificationPlacement.OPEN);
}

fn void test_probe_classification_keeps_thin_wall_front() @test {
    probe_classification_measure(ProbeClassificationPlacement.WALL_FRONT);
}

fn void test_probe_classification_excludes_thin_wall_behind() @test {
    probe_classification_measure(ProbeClassificationPlacement.WALL_BEHIND);
}

fn void test_probe_classification_uses_posed_geometry() @test {
    probe_classification_measure(ProbeClassificationPlacement.POSED_BOX);
}
