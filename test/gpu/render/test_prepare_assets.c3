module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset @public;
import c3d::camera;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::shader::compile;
import c3d::test::loading_fixtures;
import gpu;
import std::core::string;
import std::math;
import std::math::quaternion;

const usz PREPARATION_ASSET_PAYLOAD_BYTES @private = (64 << 10) + 256; // crosses the 64 KiB payload span and leaves a tail
const uint PREPARATION_ASSET_FRAME_LIMIT @private = 1024; // covers fixed material-sized staging spans and completion
const uint PREPARATION_ASSET_JOINTS @private = 261;
const uint PREPARATION_ASSET_ACTIVE_JOINT @private = 256;
const uint PREPARATION_ASSET_ZERO_JOINT @private = 260;
const uint PREPARATION_ASSET_IMAGE_SIZE @private = 64;

const String PREPARATION_ATTRIBUTE_VERTEX @private = `#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "mesh_vertex.glsl"
GPU_DECLARE_READONLY_ARRAY_REF(PreparationColors, vec4);
void main() {
    DrawRoot draw = DrawRoot(pc.vertex_root_gpu);
    GeometryRoot geometry = GeometryRoot(draw.geometry);
    FrameRoot frame = FrameRoot(draw.frame);
    uint index = uint(gl_VertexIndex);
    MeshVertexInput vertex = pull_mesh_vertex(geometry, index);
    apply_mesh_deformation(vertex, draw, geometry, index);
    vertex.color = PreparationColors(geometry.custom_data).values[index];
    write_mesh_outputs(vertex, draw, frame, geometry);
}
`;

const String PREPARATION_ATTRIBUTE_FRAGMENT @private = `#version 460
#include "generated/shader_abi.glsl"
#include "c3d_abi.glsl"
#include "custom_material.glsl"
layout(location = 5) in vec4 v_color;
layout(location = 0) out vec4 out_color;
layout(push_constant) uniform Push {
    uint64_t vertex_root_gpu;
    uint64_t fragment_root_gpu;
} pc;
void main() {
    DrawRoot draw = DrawRoot(pc.fragment_root_gpu);
    CustomMaterialGpu material = CustomMaterialGpu(draw.material);
    out_color = material_output(v_color.rgb, v_color.a, material.flags);
}
`;

fn char[]? preparation_asset_readback(Fixture* fixture, gpu::GpuSpan source, usz bytes) @private {
    Renderer* renderer = &fixture.renderer;
    gpu::AllocationDesc desc = {
        .size = bytes, .alignment = render::STREAM_ALIGNMENT,
        .memory_class = gpu::MemoryClass.CPU_READ, .access = { .graphics },
        .debug_name = "preparation_asset_readback",
    };
    gpu::MappedGpuSpan mapped = gpu::allocate_mapped_memory(&renderer.device, &desc)!;
    gpu::GpuAllocation allocation = mapped.span.allocation();
    defer gpu::free_allocation(&renderer.device, &allocation)!!;
    renderer.begin_frame()!;
    defer catch render::abort_frame(renderer);
    gpu::Barrier to_copy = { .before = { .all }, .after = { .transfer } };
    gpu::cmd_barrier(&renderer.commands, &to_copy)!;
    gpu::BufferCopyDesc copy = { .src = source.checked_subspan(0, bytes)!, .dst = mapped.span };
    gpu::cmd_copy_buffer(&renderer.commands, &copy)!;
    gpu::Barrier to_host = { .before = { .transfer }, .after = { .host } };
    gpu::cmd_barrier(&renderer.commands, &to_host)!;
    renderer.work_recorded = true;
    renderer.end_frame()!;
    render::wait_frames(renderer)!;
    gpu::invalidate_mapped_span(&renderer.device, mapped.span)!;
    char[] result = alloc::new_array(mem, char, (sz)bytes);
    mem::copy(result.ptr, mapped.bytes.ptr, (sz)bytes);
    return result;
}

fn ModelId? preparation_asset_model(
    Fixture* fixture,
    GeometryId geometry,
    MaterialId material,
    bool morphed,
) @private {
    ModelTemplate template = {
        .nodes = alloc::new_array(fixture.allocator, NodeTemplate, 1),
        .meshes = alloc::new_array(fixture.allocator, ModelMesh, 1),
    };
    defer catch asset::free_model_template(fixture.allocator, &template);
    template.nodes[0] = { .parent = -1, .local = maths::TRANSFORM_IDENTITY, .visible = true, .layers = uint::max };
    template.meshes[0] = { .node = 0, .geometry = geometry, .material = material };
    if (morphed) {
        template.meshes[0].default_morph_weights = alloc::new_array(fixture.allocator, float, 1);
        template.meshes[0].default_morph_weights[0] = 0.5f;
    }
    return fixture.assets.add_model_owned(&template);
}

fn PrepareUnit* preparation_asset_unit(
    Renderer* renderer,
    PrepareId id,
    PrepareUnitKind kind,
    GeometryId geometry,
    MaterialId material,
) @private {
    foreach (&unit : renderer.prepares.get(id).units) {
        if (unit.kind != kind) continue;
        if (kind == PrepareUnitKind.GEOMETRY && c3d::same_id(unit.geometry, geometry)) return unit;
        if (kind == PrepareUnitKind.MATERIAL && c3d::same_id(unit.material, material)) return unit;
    }
    unreachable();
}

fn void preparation_asset_drain(
    Fixture* fixture,
    PrepareId id,
    GeometryId geometry,
    MaterialId material,
    bool check_payload,
) @private {
    Renderer* renderer = &fixture.renderer;
    gpu::GpuAllocation old_payload = renderer.materials[material.index].payload;
    uint old_material_revision = renderer.materials[material.index].revision;
    bool saw_partial;
    bool checked_prefix;
    usz byte_limit = math::max(render::MATERIAL_STRIDE, (usz)1024);
    renderer.begin_frame()!!;
    PrepareReport blocked = renderer.advance_prepares_within({ .staged_bytes = 1 })!!;
    assert(blocked.reason == PrepareStopReason.STAGED_BYTES && blocked.staged_bytes == 0);
    assert(blocked.required.staged_bytes > 1);
    renderer.end_frame()!!;
    PrepareProgress progress = renderer.prepare_progress(id);
    for (uint frame = 0; frame < PREPARATION_ASSET_FRAME_LIMIT && progress.state != PrepareState.READY; frame++) {
        renderer.begin_frame()!!;
        PrepareReport report = renderer.advance_prepares_within({
            .staged_bytes = byte_limit, .generated_texels = 4096, .pipelines = 1,
        })!!;
        assert(report.staged_bytes <= byte_limit && report.generated_texels <= 4096 && report.pipelines <= 1);
        assert(renderer.stats.upload_bytes == report.staged_bytes);
        PrepareUnit* unit = preparation_asset_unit(
            renderer: renderer,
            id: id,
            kind: check_payload ? PrepareUnitKind.MATERIAL : PrepareUnitKind.GEOMETRY,
            geometry: geometry,
            material: material,
        );
        bool partial = unit.staged.bytes && !unit.done;
        if (partial) {
            saw_partial = true;
            if (check_payload) {
                assert(renderer.materials[material.index].payload == old_payload);
                assert(renderer.materials[material.index].revision == old_material_revision);
            } else {
                assert(!renderer.geometries[geometry.index].allocation.is_valid());
            }
        }
        renderer.end_frame()!!;
        if (!check_payload && partial && !checked_prefix) {
            GpuGeometry* candidate = &unit.geometry_candidate;
            char[] actual = preparation_asset_readback(
                fixture, gpu::get_allocation_span(&renderer.device, candidate.allocation)!!, unit.staged.bytes)!!;
            defer alloc::free(mem, actual.ptr);
            char[] expected = alloc::new_array(mem, char, (sz)candidate.layout.total_bytes);
            defer alloc::free(mem, expected.ptr);
            render::write_geometry_block(
                block: expected,
                geometry: &fixture.assets.geometry(geometry).data,
                layout: &candidate.layout,
                base: candidate.root,
            );
            assert(actual == expected[:actual.len]);
            checked_prefix = true;
        }
        progress = renderer.prepare_progress(id);
        assert(progress.state != PrepareState.FAILED);
    }
    assert(progress.state == PrepareState.READY && saw_partial);
    assert(progress.bytes_done == progress.bytes_total && progress.texels_done == progress.texels_total);
    assert(progress.units_done == progress.units_total);
    if (!check_payload) assert(checked_prefix);
}

fn ShaderId? preparation_attribute_shader(Fixture* fixture) @private {
    @pool() {
        asset::ShaderDesc desc = {
            .fragment = compile::compile_glsl(tmem, PREPARATION_ATTRIBUTE_FRAGMENT, ShaderStage.FRAGMENT)!,
            .vertex = {
                .shaded = compile::compile_glsl(
                    allocator: tmem,
                    source: PREPARATION_ATTRIBUTE_VERTEX,
                    stage: ShaderStage.VERTEX,
                    defines: { "SKINNED_U16", "MORPH" },
                )!,
                .depth = compile::compile_glsl(
                    allocator: tmem,
                    source: PREPARATION_ATTRIBUTE_VERTEX,
                    stage: ShaderStage.VERTEX,
                    defines: { "SKINNED_U16", "MORPH", "DEPTH_ONLY" },
                )!,
            },
        };
        return fixture.assets.add_shader(&desc);
    };
}

fn SkeletonId? preparation_asset_skeleton(Fixture* fixture) @private {
    Skeleton skeleton = {
        .joint_names = alloc::new_array(fixture.allocator, String, PREPARATION_ASSET_JOINTS),
        .parents = alloc::new_array(fixture.allocator, int, PREPARATION_ASSET_JOINTS),
        .rest_pose = alloc::new_array(fixture.allocator, Transform, PREPARATION_ASSET_JOINTS),
        .inverse_bind = alloc::new_array(fixture.allocator, Mat4, PREPARATION_ASSET_JOINTS),
    };
    defer catch asset::free_skeleton(fixture.allocator, &skeleton);
    foreach (index, &name : skeleton.joint_names) {
        *name = string::format(fixture.allocator, "preparation_joint_%d", index);
    }
    skeleton.parents[..] = -1;
    foreach (&pose : skeleton.rest_pose) *pose = maths::TRANSFORM_IDENTITY;
    foreach (&inverse : skeleton.inverse_bind) *inverse = matrix::IDENTITY4;
    return fixture.assets.add_skeleton_owned(&skeleton);
}

fn Geometry preparation_attribute_geometry(Allocator allocator) @private {
    Geometry geometry = geometry::plane(
        allocator: allocator,
        width: 2,
        depth: 2,
        segments_x: 8,
        segments_z: 8,
    );
    geometry.joints = alloc::new_array(allocator, ushort[<4>], geometry.positions.len);
    geometry.weights = alloc::new_array(allocator, Vec4, geometry.positions.len);
    foreach (&joints : geometry.joints) *joints = { 0, PREPARATION_ASSET_ACTIVE_JOINT, PREPARATION_ASSET_ZERO_JOINT, 0 };
    foreach (&weights : geometry.weights) *weights = { 0.5f, 0.5f, 0, 0 };
    geometry.targets = alloc::new_array(allocator, MorphTarget, 1);
    geometry.targets[0] = {
        .position_deltas = alloc::new_array(allocator, Vec3, geometry.positions.len),
        .normal_deltas = alloc::new_array(allocator, Vec3, geometry.positions.len),
    };
    foreach (&delta : geometry.targets[0].position_deltas) *delta = { 0, 0, 0.25f };
    geometry.custom_stride = Vec4::size;
    geometry.custom_data = alloc::new_array(allocator, char, (sz)(geometry.positions.len * Vec4::size));
    Vec4[] colors = ((Vec4*)geometry.custom_data.ptr)[:geometry.positions.len];
    foreach (index, &color : colors) {
        *color = { 0.2f + (float)(index % 9) / 16, 0.2f + (float)(index / 9) / 16, 0.5f, 1 };
    }
    return geometry;
}

fn DeformedScene? preparation_asset_scene(
    Fixture* fixture,
    GeometryId geometry,
    MaterialId material,
    SkeletonId skeleton = {},
) @private {
    DeformedScene result;
    result.scene = scene::create_scene(fixture.allocator, scene::default_scene_desc());
    defer catch scene::destroy_scene(&result.scene);
    result.mesh = result.scene.add_mesh(geometry, material)!;
    if (skeleton.generation) {
        Quat upright = quaternion::from_axis_angle{float}({ 1, 0, 0 }, (float)math::PI * 0.5f);
        result.mesh.local.rotation = upright;
        Mesh* mesh = result.scene.get(result.mesh, Mesh);
        mesh.morph_weights = alloc::new_array(result.scene.allocator, float, 1);
        mesh.morph_weights[0] = 0.5f;
        Node*[] joints = alloc::new_array(result.scene.allocator, Node*, PREPARATION_ASSET_JOINTS);
        foreach (index, &joint : joints) {
            *joint = result.scene.add_node()!;
            (*joint).local.rotation = upright;
            (*joint).local.position.x = index == PREPARATION_ASSET_ACTIVE_JOINT ? 0.125f : 0.0625f;
        }
        result.scene.add(result.mesh, (SkinBinding){ .skeleton = skeleton, .joints = joints });
    }
    result.camera = result.scene.add_camera(camera::perspective_deg(60, 0.1f))!;
    result.camera.local.position = CAMERA_POSITION;
    result.scene.update_world();
    return result;
}

fn Vec4[]? preparation_asset_image(
    Fixture* fixture,
    DeformedScene* scene,
    ViewId view,
    RenderTargetId target,
) @private {
    Renderer* renderer = &fixture.renderer;
    scene.scene.update_world();
    renderer.begin_frame({ .time = 1, .delta = 1.0f / 60 })!;
    defer catch render::abort_frame(renderer);
    renderer.render_view(&scene.scene, scene.camera, view)!;
    renderer.finish_view(view)!;
    renderer.end_frame()!;
    return read_float_target(fixture, target);
}

fn void preparation_asset_draw_parity(
    Fixture* fixture,
    DeformedScene* stepped,
    DeformedScene* synchronous,
) @private {
    RenderTargetId target = render::create_render_target(
        renderer: &fixture.renderer,
        desc: render::render_target_desc(PREPARATION_ASSET_IMAGE_SIZE, PREPARATION_ASSET_IMAGE_SIZE, RGBA32_FLOAT),
    )!!;
    defer render::destroy_render_target(&fixture.renderer, target)!!;
    ViewDesc desc = render::texture_view_desc(target);
    desc.shading = ShadingPath.FORWARD;
    desc.lights = LightSelection.FLAT;
    desc.post.anti_aliasing = AntiAliasing.NONE;
    ViewId view = render::create_view(&fixture.renderer, desc)!!;
    defer render::destroy_view(&fixture.renderer, view)!!;
    Vec4[] actual = preparation_asset_image(
        fixture: fixture,
        scene: stepped,
        view: view,
        target: target,
    )!!;
    defer alloc::free(mem, actual.ptr);
    Vec4[] expected = preparation_asset_image(
        fixture: fixture,
        scene: synchronous,
        view: view,
        target: target,
    )!!;
    defer alloc::free(mem, expected.ptr);
    assert(actual == expected);
    bool visible;
    foreach (pixel : actual) visible |= pixel.x + pixel.y + pixel.z > 0.01f;
    assert(visible);
}

fn void preparation_geometry_bytes(Fixture* fixture, GeometryId geometry) @private {
    Renderer* renderer = &fixture.renderer;
    GpuGeometry* mirror = &renderer.geometries[geometry.index];
    char[] actual = preparation_asset_readback(
        fixture, gpu::get_allocation_span(&renderer.device, mirror.allocation)!!, mirror.layout.total_bytes)!!;
    defer alloc::free(mem, actual.ptr);
    char[] expected = alloc::new_array(mem, char, (sz)mirror.layout.total_bytes);
    defer alloc::free(mem, expected.ptr);
    render::write_geometry_block(
        block: expected,
        geometry: &fixture.assets.geometry(geometry).data,
        layout: &mirror.layout,
        base: mirror.root,
    );
    assert(actual == expected);
}

fn void test_prepare_geometry_ranges_readback_and_deformed_custom_draw_match_sync() @test {
    Fixture fixture;
    create_fixture(mem, &fixture)!!;
    defer destroy_fixture(&fixture);
    @pool() {
        Geometry source = preparation_attribute_geometry(tmem);
        GeometryId stepped = fixture.assets.add_geometry(&source)!!;
        GeometryId synchronous = fixture.assets.add_geometry(&source)!!;
        ShaderId shader = preparation_attribute_shader(&fixture)!!;
        MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
        common.double_sided = true;
        MaterialId material = fixture.assets.add_material(material::custom(shader, common: common))!!;
        ModelId model = preparation_asset_model(
            fixture: &fixture,
            geometry: stepped,
            material: material,
            morphed: true,
        )!!;
        PrepareId id = fixture.renderer.begin_prepare_model(model)!!;
        preparation_asset_drain(
            fixture: &fixture,
            id: id,
            geometry: stepped,
            material: material,
            check_payload: false,
        );
        fixture.renderer.end_prepare(id)!!;
        assert(fixture.renderer.geometries[stepped.index].layout.flags.joints_u16);
        preparation_geometry_bytes(&fixture, stepped);
        fixture.renderer.upload_geometry(synchronous)!!;
        SkeletonId skeleton = preparation_asset_skeleton(&fixture)!!;
        DeformedScene actual = preparation_asset_scene(
            fixture: &fixture,
            geometry: stepped,
            material: material,
            skeleton: skeleton,
        )!!;
        defer scene::destroy_scene(&actual.scene);
        DeformedScene expected = preparation_asset_scene(
            fixture: &fixture,
            geometry: synchronous,
            material: material,
            skeleton: skeleton,
        )!!;
        defer scene::destroy_scene(&expected.scene);
        preparation_asset_draw_parity(&fixture, &actual, &expected);
    };
    check_validation(&fixture.renderer);
}

fn ShaderId? preparation_large_reference_shader(Fixture* fixture) @private {
    @pool() {
        asset::ShaderDesc desc = {
            .fragment = compile::compile_glsl(tmem, (String)REFERENCE_FRAGMENT_SOURCE[..], ShaderStage.FRAGMENT)!,
            .param_block_size = PREPARATION_ASSET_PAYLOAD_BYTES,
        };
        return fixture.assets.add_shader(&desc);
    };
}

fn void preparation_payload_bytes(Fixture* fixture, MaterialId material, char[] expected) @private {
    Renderer* renderer = &fixture.renderer;
    MaterialRes* mirror = &renderer.materials[material.index];
    assert(mirror.payload_size == expected.len);
    char[] actual = preparation_asset_readback(
        fixture, gpu::get_allocation_span(&renderer.device, mirror.payload)!!, expected.len)!!;
    defer alloc::free(mem, actual.ptr);
    assert(actual == expected);
}

fn void preparation_payload_mode(usz allowance) @private {
    Fixture fixture;
    create_fixture(
        allocator: mem,
        fixture: &fixture,
        texture_budget_bytes: 16,
    )!!;
    defer destroy_fixture(&fixture);
    @pool() {
        ShaderId shader = preparation_large_reference_shader(&fixture)!!;
        char[] old_bytes = loading_fixtures::preparation_texture_bytes(tmem, PREPARATION_ASSET_PAYLOAD_BYTES);
        char[] bytes = loading_fixtures::preparation_texture_bytes(
            tmem, PREPARATION_ASSET_PAYLOAD_BYTES, loading_fixtures::PREPARATION_IMAGE_SEED ^ 17);
        MaterialId old_layer = fixture.assets.add_material(material::standard())!!;
        MaterialId stepped = fixture.assets.add_material(material::custom(
            shader: shader,
            param_block: old_bytes,
            references: { [0] = old_layer, [1] = old_layer, [2] = old_layer },
        ))!!;
        fixture.renderer.upload_material(stepped)!!;
        material::TextureDesc texture_desc = material::texture_2d_desc(256, 128, RGBA8_UNORM);
        char[] pixels = loading_fixtures::preparation_texture_bytes(tmem, 256 * 128 * 4);
        TextureId texture = fixture.assets.add_texture(texture_desc, pixels)!!;
        StandardParams params = material::STANDARD_PARAMS_DEFAULT;
        params.base_color_map = material::texture_slot(texture, asset::SAMPLER_NEAREST);
        params.emissive = { 0.1f, 0.15f, 0.2f };
        MaterialId layer = fixture.assets.add_material(material::standard(params))!!;
        Material replacement = material::custom(
            shader: shader,
            param_block: bytes,
            slots: { [0] = material::texture_slot(texture,
            asset::SAMPLER_NEAREST) },
            references: { [0] = layer, [1] = layer, [2] = layer },
        );
        fixture.assets.replace_material(stepped, replacement);
        MaterialId synchronous = fixture.assets.add_material(replacement)!!;
        ModelId model = preparation_asset_model(
            fixture: &fixture,
            geometry: fixture.box,
            material: stepped,
            morphed: false,
        )!!;
        PrepareId id = fixture.renderer.begin_prepare_model(model)!!;
        uint texture_units;
        uint layer_units;
        foreach (unit : fixture.renderer.prepares.get(id).units) {
            if (unit.kind == PrepareUnitKind.TEXTURE && c3d::same_id(unit.texture, texture)) {
                texture_units++;
                assert(unit.full_reader && unit.texture_base == 0);
            }
            if (unit.kind == PrepareUnitKind.MATERIAL && c3d::same_id(unit.material, layer)) layer_units++;
        }
        assert(texture_units == 1 && layer_units == 1);
        if (allowance == 1024) {
            preparation_asset_drain(
                fixture: &fixture,
                id: id,
                geometry: fixture.box,
                material: stepped,
                check_payload: true,
            );
        } else {
            preparation_drain(&fixture.renderer, id, {
                .staged_bytes = allowance, .generated_texels = 4096, .pipelines = 1,
            });
        }
        fixture.renderer.end_prepare(id)!!;
        assert(fixture.renderer.residencies[texture.index].resident_base == 0);
        preparation_payload_bytes(&fixture, stepped, bytes);
        fixture.renderer.upload_material(synchronous)!!;
        preparation_payload_bytes(&fixture, synchronous, bytes);
        usz actual_offset = (usz)stepped.index * render::MATERIAL_STRIDE;
        usz expected_offset = (usz)synchronous.index * render::MATERIAL_STRIDE;
        char[] actual = preparation_asset_readback(
            &fixture, fixture.renderer.material_heap_span.checked_subspan(actual_offset, CustomMaterialGpu::size)!!,
            CustomMaterialGpu::size)!!;
        defer alloc::free(mem, actual.ptr);
        char[] expected = preparation_asset_readback(
            &fixture, fixture.renderer.material_heap_span.checked_subspan(expected_offset, CustomMaterialGpu::size)!!,
            CustomMaterialGpu::size)!!;
        defer alloc::free(mem, expected.ptr);
        CustomMaterialGpu normalized = *(CustomMaterialGpu*)expected.ptr;
        normalized.parameters = ((CustomMaterialGpu*)actual.ptr).parameters;
        assert(mem::equals(actual.ptr, (char*)&normalized, CustomMaterialGpu::size));
        CustomMaterialGpu* block = (CustomMaterialGpu*)actual.ptr;
        gpu::GpuAddress layer_address = fixture.renderer.materials[layer.index].address;
        assert(block.references[0] == layer_address && block.references[1] == layer_address
          && block.references[2] == layer_address);
        assert(block.parameters == fixture.renderer.materials[stepped.index].payload_address);
        DeformedScene target = preparation_asset_scene(
            fixture: &fixture,
            geometry: fixture.box,
            material: stepped,
        )!!;
        defer scene::destroy_scene(&target.scene);
        DeformedScene reference = preparation_asset_scene(
            fixture: &fixture,
            geometry: fixture.box,
            material: synchronous,
        )!!;
        defer scene::destroy_scene(&reference.scene);
        preparation_asset_draw_parity(&fixture, &target, &reference);
    };
    check_validation(&fixture.renderer);
}

fn void test_prepare_large_custom_payload_and_repeated_layers_match_sync() @test {
    foreach (allowance : (usz[4]){ 1024, 1 << 20, 8 << 20, 0 }) preparation_payload_mode(allowance);
}
