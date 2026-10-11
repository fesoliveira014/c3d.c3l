module c3d::render::acceptance;

import c3d;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import gpu;
import std::math;

const float PROBE_PHYSICAL_BOX_HALF_EXTENT @private = 2;
const Vec3 PROBE_PHYSICAL_HALF_EXTENTS @private = { 0.125f, 0.125f, 0.125f };
const uint PROBE_PHYSICAL_RAYS @private = light::PROBE_RAYS_MIN;
const double PROBE_PHYSICAL_ABSOLUTE @private = 2e-5;
const double PROBE_PHYSICAL_RELATIVE @private = 2e-4;
const Vec3 PROBE_PHYSICAL_EMISSION @private = { 0.25f, 0.5f, 1 };
const double PROBE_PHYSICAL_COAT @private = 0.5;
const double PROBE_PHYSICAL_ROUGHNESS @private = 0.5;

fn Vec3 probe_physical_direction(uint index, uint frame_index) @private {
    Quat rotation = maths::random_rotation({
        maths::halton(frame_index + 1, 2),
        maths::halton(frame_index + 1, 3),
        maths::halton(frame_index + 1, 5),
    });
    return rotation.rotate_vec3(maths::spherical_fibonacci(index, PROBE_PHYSICAL_RAYS));
}

fn void test_probe_physical_outgoing_coat_and_emission_match_independent_ray_reference() @test {
    foreach (hardware : (bool[2]){ false, true }) {
        foreach (double_sided : (bool[2]){ false, true }) {
            Fixture fixture;
            create_fixture(mem, &fixture, ray_queries: hardware)!!;
            defer destroy_fixture(&fixture);
            Scene scene = scene::create_scene(mem, scene::default_scene_desc());
            defer scene::destroy_scene(&scene);
            scene.ambient_intensity = 0;
            PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
            params.standard.base_color = { 0, 0, 0, 1 };
            params.standard.metallic = 0;
            params.standard.emissive = PROBE_PHYSICAL_EMISSION;
            params.specular = 0;
            params.clearcoat = (float)PROBE_PHYSICAL_COAT;
            params.clearcoat_roughness = (float)PROBE_PHYSICAL_ROUGHNESS;
            MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
            common.double_sided = double_sided;
            MaterialId material_id = fixture.assets.add_material(material::physical(params, common))!!;
            GeometryId geometry_id;
            @pool() {
                Geometry geometry = geometry::box(
                    allocator: tmem,
                    width: 2 * PROBE_PHYSICAL_BOX_HALF_EXTENT,
                    height: 2 * PROBE_PHYSICAL_BOX_HALF_EXTENT,
                    depth: 2 * PROBE_PHYSICAL_BOX_HALF_EXTENT,
                );
                geometry_id = fixture.assets.add_geometry(&geometry)!!;
            };
            scene.add_mesh(geometry_id, material_id)!!;
            Node* light_node = scene.add_light(light::directional({ 1, 1, 1 }, 1, false))!!;
            light_node.layers = 2;
            scene.get(light_node, Light).layers = 1;
            Node* volume_node = scene.add_node(name: "physical_hit_probe")!!;
            volume_node.local.position = PROBE_PHYSICAL_HALF_EXTENTS;
            ProbeVolume volume = light::probe_volume(PROBE_PHYSICAL_HALF_EXTENTS, { 2, 2, 2 }, SCENE);
            volume.update.rays_per_probe = PROBE_PHYSICAL_RAYS;
            volume.update.hysteresis = 0;
            scene.add(volume_node, volume);
            Node* camera_node = scene.add_camera(camera::orthographic(5, 0.1f, 20))!!;
            camera_node.local.position = { 0, 0, 5 };
            scene.get(camera_node, Camera).layers = 1;
            scene.update_world();
            Renderer* renderer = &fixture.renderer;
            usz ray_bytes = PROBE_PHYSICAL_RAYS * RayResultGpu::size;
            gpu::AllocationDesc readback_desc = {
                .size = ray_bytes,
                .alignment = 16,
                .memory_class = gpu::MemoryClass.CPU_READ,
                .access = { .graphics },
                .debug_name = "probe_physical_rays",
            };
            gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &readback_desc)!!;
            defer {
                gpu::GpuAllocation allocation = readback.span.allocation();
                gpu::free_allocation(&renderer.device, &allocation)!!;
            }
            uint frame_index = (uint)renderer.frame_index;
            renderer.begin_frame()!!;
            defer catch render::abort_frame(renderer);
            renderer.render_view(&scene, camera_node, fixture.view)!!;
            assert(renderer.stats.probe_updates == 1);
            assert(renderer.stats.probe_rays == 8 * PROBE_PHYSICAL_RAYS);
            assert(renderer.stats.trace_lights == 0 && renderer.stats.trace_lights_dropped == 0);
            gpu::Barrier transfer = { .before = { .all }, .after = { .transfer } };
            gpu::cmd_barrier(&renderer.commands, &transfer)!!;
            gpu::GpuSpan source = gpu::get_allocation_span(&renderer.device, renderer.probe_update.rays)!!;
            gpu::BufferCopyDesc copy = { .src = source.checked_subspan(0, ray_bytes)!!, .dst = readback.span };
            gpu::cmd_copy_buffer(&renderer.commands, &copy)!!;
            gpu::Barrier host = { .before = { .transfer }, .after = { .host } };
            gpu::cmd_barrier(&renderer.commands, &host)!!;
            renderer.finish_view(fixture.view)!!;
            renderer.end_frame()!!;
            render::wait_frames(renderer)!!;
            gpu::invalidate_mapped_span(&renderer.device, readback.span)!!;
            RayResultGpu[] rays = ((RayResultGpu*)readback.bytes.ptr)[:PROBE_PHYSICAL_RAYS];
            uint direct_count;
            uint attenuated_count;
            foreach (index, ray : rays) {
                Vec3 direction = probe_physical_direction((uint)index, frame_index);
                uint axis;
                if (math::abs(direction.y) > math::abs(direction.x)) axis = 1;
                if (math::abs(direction.z) > math::abs(direction[axis])) axis = 2;
                double normal_view = math::abs((double)direction[axis]);
                double distance = (double)PROBE_PHYSICAL_BOX_HALF_EXTENT / normal_view;
                assert(math::is_finite(ray.radiance_distance.w));
                double expected_distance = double_sided ? distance : -distance;
                double distance_error = math::abs((double)ray.radiance_distance.w - expected_distance);
                assert(distance_error <= PROBE_PHYSICAL_ABSOLUTE + PROBE_PHYSICAL_RELATIVE * distance);
                if (!double_sided) {
                    assert(ray.radiance_distance.xyz == (Vec3){});
                    continue;
                }
                double complement = 1 - normal_view;
                double weight = PROBE_PHYSICAL_COAT * (0.04 + 0.96 * math::pow(complement, 5.0));
                double direct;
                if (axis == 2 && direction.z < 0) {
                    double half_length = math::sqrt(2 - 2 * (double)direction.z);
                    double normal_half = (1 - (double)direction.z) / half_length;
                    double alpha = PROBE_PHYSICAL_ROUGHNESS * PROBE_PHYSICAL_ROUGHNESS;
                    double alpha_squared = alpha * alpha;
                    double cosine_squared = normal_half * normal_half;
                    double denominator = 1 - cosine_squared + alpha_squared * cosine_squared;
                    double distribution = alpha_squared / (math::PI * denominator * denominator);
                    double visibility = 0.5 / (math::sqrt(alpha_squared + (1 - alpha_squared)
                        * normal_view * normal_view) + normal_view);
                    direct = weight * distribution * visibility;
                    direct_count++;
                }
                attenuated_count += weight > 0 ? 1 : 0;
                for (uint channel = 0; channel < 3; channel++) {
                    double expected = (1 - weight) * (double)PROBE_PHYSICAL_EMISSION[channel] + direct;
                    double error = math::abs((double)ray.radiance_distance[channel] - expected);
                    assert(error <= PROBE_PHYSICAL_ABSOLUTE + PROBE_PHYSICAL_RELATIVE * math::abs(expected),
                        "Probe Physical mismatch: backend=%s ray=%s channel=%s expected=%s actual=%s",
                        hardware, index, channel, expected, ray.radiance_distance[channel]);
                }
            }
            if (double_sided) assert(direct_count > 0 && attenuated_count == PROBE_PHYSICAL_RAYS);
            check_validation(renderer);
        }
    }
}
