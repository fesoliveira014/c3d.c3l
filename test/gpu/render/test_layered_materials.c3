module c3d::render::acceptance;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import c3d::test::transparency_fixtures;
import gpu;
import std::math;

const transparency_fixtures::Color LAYERED_ROW_RADIANCE @private = { 0.8, 0.4, 0.2 };
const float LAYERED_ROW_COVERAGE @private = 0.5f;
const float LAYERED_JOINT_TRANSLATION @private = 0.5f;
const float LAYERED_MORPH_TRANSLATION @private = 0.25f;
const float LAYERED_MORPH_WEIGHT @private = 0.5f;
const uint LAYERED_WIDE_JOINT @private = 256;
const double LAYERED_VERTEX_DEPTH_TOLERANCE @private = 4 * math::FLOAT_EPSILON; // CPU/raster rounding; exact keys.

enum LayeredMaterialPath @private {
    MESH,
    REVERSED,
    INSTANCED,
    MIRRORED,
    SKIN_BYTE,
    SKIN_WIDE,
    MORPH,
    SKIN_MORPH,
    BILLBOARD,
}

struct LayeredMaterialRow @private {
    MaterialKind kind;
    LayeredMaterialPath path;
    bool additive;
}

const LayeredMaterialRow[16] LAYERED_MATERIAL_ROWS @private = {
    { .kind = BASIC, .path = MESH },
    { .kind = BASIC, .path = MIRRORED },
    { .kind = BASIC, .path = SKIN_BYTE },
    { .kind = BASIC, .path = BILLBOARD, .additive = true },
    { .kind = STANDARD, .path = MESH },
    { .kind = STANDARD, .path = INSTANCED },
    { .kind = STANDARD, .path = SKIN_WIDE },
    { .kind = STANDARD, .path = BILLBOARD },
    { .kind = TOON, .path = REVERSED },
    { .kind = TOON, .path = MIRRORED },
    { .kind = TOON, .path = MORPH, .additive = true },
    { .kind = TOON, .path = BILLBOARD },
    { .kind = PHYSICAL, .path = MESH },
    { .kind = PHYSICAL, .path = MIRRORED },
    { .kind = PHYSICAL, .path = SKIN_MORPH },
    { .kind = PHYSICAL, .path = BILLBOARD, .additive = true },
};

fn bool layered_path_skinned(LayeredMaterialPath path) @private {
    return path == SKIN_BYTE || path == SKIN_WIDE || path == SKIN_MORPH;
}

fn bool layered_path_morphed(LayeredMaterialPath path) @private {
    return path == MORPH || path == SKIN_MORPH;
}

fn bool layered_path_instanced(LayeredMaterialPath path) @private {
    return path == INSTANCED || path == MIRRORED;
}

fn MaterialId? add_layered_row_material(Fixture* fixture, LayeredMaterialRow row) @private {
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    common.alpha_mode = AlphaMode.BLEND;
    common.double_sided = true;
    common.blend_mode = row.additive ? BlendMode.ADDITIVE : BlendMode.PREMULTIPLIED_ALPHA;
    Vec4 color = { 0.8f, 0.4f, 0.2f, LAYERED_ROW_COVERAGE };
    switch (row.kind) {
        case BASIC:
            return fixture.assets.add_material(material::basic({ .color = color }, common));
        case STANDARD:
            StandardParams params = material::STANDARD_PARAMS_DEFAULT;
            params.base_color = { 0, 0, 0, LAYERED_ROW_COVERAGE };
            params.metallic = 0;
            params.emissive = { color.x, color.y, color.z };
            return fixture.assets.add_material(material::standard(params, common));
        case TOON:
            ToonParams params = material::TOON_PARAMS_DEFAULT;
            params.color = color;
            return fixture.assets.add_material(material::toon(params, common));
        case PHYSICAL:
            PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
            params.standard.base_color = { 0, 0, 0, LAYERED_ROW_COVERAGE };
            params.standard.metallic = 0;
            params.standard.emissive = { color.x, color.y, color.z };
            return fixture.assets.add_material(material::physical(params, common));
        case CUSTOM: return c3d::UNSUPPORTED~;
    }
}

fn GeometryId? add_layered_row_geometry(
    Fixture* fixture,
    LayeredMaterialPath path,
    float depth = 0.5f,
) @private {
    @pool() {
        Vec3[4] positions = {
            { -0.75f, -0.75f, 8 * depth - 9 },
            { 0.75f, -0.75f, 8 * depth - 9 },
            { 0.75f, 0.75f, 8 * depth - 9 },
            { -0.75f, 0.75f, 8 * depth - 9 },
        };
        Vec2[4] uv = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } };
        Geometry geometry = {
            .positions = positions[..],
            .uv0 = uv[..],
            .indices = path == REVERSED || path == SKIN_WIDE
              ? transparency_fixtures::REVERSED_QUAD_INDICES[..] : transparency_fixtures::QUAD_INDICES[..],
        };
        if (layered_path_skinned(path)) {
            ushort joint = path == SKIN_WIDE ? (ushort)LAYERED_WIDE_JOINT : 1;
            geometry.joints = alloc::new_array(tmem, ushort[<4>], 4);
            geometry.weights = alloc::new_array(tmem, Vec4, 4);
            float[4] weights = { 0, 0.5f, 1, 0.5f };
            foreach (corner, weight : weights) {
                geometry.joints[corner] = { 0, joint, 0, 0 };
                geometry.weights[corner] = { 1 - weight, weight, 0, 0 };
            }
        }
        if (layered_path_morphed(path)) {
            geometry.targets = alloc::new_array(tmem, MorphTarget, 1);
            geometry.targets[0].position_deltas = alloc::new_array(tmem, Vec3, 4);
            geometry.targets[0].normal_deltas = alloc::new_array(tmem, Vec3, 4);
            geometry.targets[0].position_deltas[..] = { 0, 0, LAYERED_MORPH_TRANSLATION };
        }
        geometry.finalize();
        return fixture.assets.add_geometry(&geometry);
    };
}

fn void? attach_layered_row_skin(
    Fixture* fixture,
    LayeredScene* target,
    Node* node,
    bool wide,
) @private {
    uint count = wide ? LAYERED_WIDE_JOINT + 1 : 2;
    Skeleton skeleton = {
        .joint_names = alloc::new_array(fixture.allocator, String, count),
        .parents = alloc::new_array(fixture.allocator, int, count),
        .rest_pose = alloc::new_array(fixture.allocator, Transform, count),
        .inverse_bind = alloc::new_array(fixture.allocator, Mat4, count),
    };
    foreach (joint, &parent : skeleton.parents) {
        *parent = -1;
        skeleton.rest_pose[joint] = maths::TRANSFORM_IDENTITY;
        skeleton.inverse_bind[joint] = matrix::IDENTITY4;
    }
    SkeletonId skeleton_id = fixture.assets.add_skeleton_owned(&skeleton)!;
    Node*[] joints = alloc::new_array(target.scene.allocator, Node*, count);
    foreach (&joint : joints) *joint = target.scene.add_node()!;
    joints[count - 1].local.position.z = LAYERED_JOINT_TRANSLATION;
    target.scene.add(node, (SkinBinding){ .skeleton = skeleton_id, .joints = joints });
}

fn Node*? add_layered_row_node(
    Fixture* fixture,
    LayeredScene* target,
    MaterialId material,
    LayeredMaterialPath path,
    float depth = 0.5f,
) @private {
    if (path == BILLBOARD) {
        Billboard[1] billboards = { scene::BILLBOARD_DEFAULT };
        billboards[0].position = { 0, 0, 8 * depth - 9 };
        billboards[0].size = { 1.5f, 1.5f };
        return target.scene.add_billboards(
            material: material,
            capacity: 1,
            billboards: billboards[..],
        );
    }
    GeometryId geometry = add_layered_row_geometry(fixture, path, depth)!;
    if (layered_path_instanced(path)) {
        Node* node = target.scene.add_instanced_mesh(geometry, material, 2)!;
        target.scene.resize_instances(node, 2)!;
        InstancedMesh* batch = target.scene.get(node, InstancedMesh);
        batch.transforms[0] = batch.transforms[1] = maths::TRANSFORM_IDENTITY;
        batch.transforms[1].position.z = 1;
        if (path == MIRRORED) batch.transforms[0].scale.x = -1;
        target.scene.mark_instances_dirty(node);
        return node;
    }
    Node* node = target.scene.add_mesh(geometry, material)!;
    if (layered_path_skinned(path)) {
        attach_layered_row_skin(
            fixture: fixture,
            target: target,
            node: node,
            wide: path == SKIN_WIDE,
        )!;
    }
    if (layered_path_morphed(path)) {
        Mesh* mesh = target.scene.get(node, Mesh);
        mesh.morph_weights = alloc::new_array(target.scene.allocator, float, 1);
        mesh.morph_weights[0] = LAYERED_MORPH_WEIGHT;
    }
    return node;
}

fn uint[]? read_layered_material_anchor(Fixture* fixture, LayeredView* view) @private {
    Renderer* renderer = &fixture.renderer;
    Target* anchor = &renderer.views.get(view.view).transparency.continuation_depth[0];
    render::wait_frames(renderer)!;
    render::open_closed_frame_slot(renderer)!;
    gpu::AllocationDesc desc = {
        .size = (usz)anchor.width * anchor.height * uint::size,
        .memory_class = gpu::MemoryClass.CPU_READ,
        .access = { .graphics },
        .debug_name = "layered_shaded_depth_readback",
    };
    gpu::MappedGpuSpan readback = gpu::allocate_mapped_memory(&renderer.device, &desc)!;
    defer {
        gpu::GpuAllocation allocation = readback.span.allocation();
        (void)gpu::free_allocation(&renderer.device, &allocation);
    }
    TextureReadback copy = { .target = anchor, .destination = readback.span };
    render::submit_pending(renderer, &copy)!;
    gpu::invalidate_mapped_span(&renderer.device, readback.span)!;
    uint[] bits = mem::new_array(uint, (usz)anchor.width * anchor.height);
    bits[..] = ((uint*)readback.bytes.ptr)[:bits.len];
    return bits;
}

fn double layered_row_depth(LayeredMaterialPath path, uint row, uint column) @private {
    double depth = layered_path_instanced(path) ? 0.625 : 0.5;
    if (layered_path_skinned(path)) {
        double x = -1 + 2 * ((double)column + 0.5) / LAYERED_IMAGE_SIZE;
        double y = 1 - 2 * ((double)row + 0.5) / LAYERED_IMAGE_SIZE;
        double weight = 0.5 + (x + y) / 3;
        depth += (double)LAYERED_JOINT_TRANSLATION * weight / 8;
    }
    if (layered_path_morphed(path)) {
        depth += (double)LAYERED_MORPH_TRANSLATION * LAYERED_MORPH_WEIGHT / 8;
    }
    return depth;
}

fn void test_layered_material_families_and_vertex_paths_match_known_radiance_and_depth() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    foreach (row : LAYERED_MATERIAL_ROWS) {
        LayeredScene target = create_layered_scene(&fixture)!!;
        defer scene::destroy_scene(&target.scene);
        target.scene.ambient_color = { 1, 1, 1 };
        target.scene.ambient_intensity = 1;
        LayeredView view = create_layered_view(&fixture)!!;
        defer destroy_layered_view(&fixture, &view);
        MaterialId material = add_layered_row_material(&fixture, row)!!;
        Node* node = add_layered_row_node(
            fixture: &fixture,
            target: &target,
            material: material,
            path: row.path,
        )!!;
        if (row.path == SKIN_WIDE) {
            assert(fixture.assets.geometry(target.scene.get(node, Mesh).geometry).joints_u16);
        }
        transparency_fixtures::Color expected = transparency_fixtures::PLANAR_BACKGROUND;
        uint layers = layered_path_instanced(row.path) ? 2 : 1;
        for (uint layer = 0; layer < layers; layer++) {
            expected = row.additive
              ? transparency_fixtures::compose_additive(expected, LAYERED_ROW_RADIANCE, LAYERED_ROW_COVERAGE)
              : transparency_fixtures::compose_over(expected, LAYERED_ROW_RADIANCE, LAYERED_ROW_COVERAGE);
        }
        Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(pixels);
        check_layered_interior(pixels, expected);
        uint[] captured = read_layered_depth(&fixture, &view, 0)!!;
        defer free(captured);
        uint[] shaded = read_layered_material_anchor(&fixture, &view)!!;
        defer free(shaded);
        for (uint y = LAYERED_INTERIOR_BEGIN; y < LAYERED_INTERIOR_END; y++) {
            for (uint x = LAYERED_INTERIOR_BEGIN; x < LAYERED_INTERIOR_END; x++) {
                uint pixel = y * LAYERED_IMAGE_SIZE + x;
                assert(captured[pixel] == shaded[pixel], "Capture and shade depth bits diverge.");
                double actual = bitcast(captured[pixel], float);
                assert(math::abs(actual - layered_row_depth(row.path, y, x)) <= LAYERED_VERTEX_DEPTH_TOLERANCE);
            }
        }
        if (layers == 2) {
            uint[] farther = read_layered_depth(&fixture, &view, 1)!!;
            defer free(farther);
            uint sample = LAYERED_SAMPLE_ROW * LAYERED_IMAGE_SIZE + LAYERED_SAMPLE_COLUMN;
            assert(farther[sample] == bitcast(0.5f, uint));
        }
    }
    check_validation(&fixture.renderer);
}

fn void test_layered_positive_physical_transmission_applies_authored_tint_once_on_vertex_paths() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    LayeredMaterialPath[5] paths = { MESH, MIRRORED, SKIN_BYTE, SKIN_WIDE, MORPH };
    foreach (path : paths) {
        foreach (alpha_mode : (AlphaMode[3]){ OPAQUE, MASK, BLEND }) {
            LayeredScene target = create_layered_scene(&fixture)!!;
            defer scene::destroy_scene(&target.scene);
            LayeredView view = create_layered_view(&fixture)!!;
            defer destroy_layered_view(&fixture, &view);
            MaterialId behind = add_layered_basic(&fixture, { 0, 0, 1, 0.5f })!!;
            GeometryId rear = add_layered_sheet_geometry(&fixture, 0.25f)!!;
            target.scene.add_mesh(rear, behind)!!;
            PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
            params.standard.base_color = { 0.8f, 0.6f, 0.4f, 0.5f };
            params.standard.metallic = 0;
            params.standard.roughness = 0;
            params.ior = 1;
            params.specular = 0;
            params.transmission = 1;
            params.thickness = 0;
            MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
            common.alpha_mode = alpha_mode;
            common.double_sided = true;
            MaterialId glass = fixture.assets.add_material(material::physical(params, common))!!;
            add_layered_row_node(
                fixture: &fixture,
                target: &target,
                material: glass,
                path: path,
                depth: 0.75f,
            )!!;
            transparency_fixtures::Color expected = transparency_fixtures::compose_over(
                behind: transparency_fixtures::PLANAR_BACKGROUND,
                radiance: { 0, 0, 1 },
                coverage: 0.5,
            );
            transparency_fixtures::Color tint = { 0.8, 0.6, 0.4 };
            transparency_fixtures::Color factor = alpha_mode == BLEND
              ? 0.5 * tint + (transparency_fixtures::Color){ 0.5, 0.5, 0.5 } : tint;
            uint layers = layered_path_instanced(path) ? 2 : 1;
            for (uint layer = 0; layer < layers; layer++) expected *= factor;
            Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
            defer free(pixels);
            check_layered_interior(pixels, expected);
            uint[] captured = read_layered_depth(&fixture, &view, 0)!!;
            defer free(captured);
            uint[] shaded = read_layered_material_anchor(&fixture, &view)!!;
            defer free(shaded);
            for (uint y = LAYERED_INTERIOR_BEGIN; y < LAYERED_INTERIOR_END; y++) {
                for (uint x = LAYERED_INTERIOR_BEGIN; x < LAYERED_INTERIOR_END; x++) {
                    uint pixel = y * LAYERED_IMAGE_SIZE + x;
                    assert(captured[pixel] == shaded[pixel]);
                    double actual = bitcast(captured[pixel], float);
                    double expected_depth = layered_row_depth(path, y, x) + 0.25;
                    assert(math::abs(actual - expected_depth) <= LAYERED_VERTEX_DEPTH_TOLERANCE);
                }
            }
        }
    }
    check_validation(&fixture.renderer);
}

fn TextureId? add_layered_alpha_map(Fixture* fixture, char first, char second) @private {
    char[8] pixels = { 255, 255, 255, first, 255, 255, 255, second };
    material::TextureDesc desc = {
        .width = 2,
        .height = 1,
        .layers = 1,
        .format = PixelFormat.RGBA8_UNORM,
        .mip_levels = 1,
        .debug_name = "layered_alpha_map",
    };
    return fixture.assets.add_texture(desc, pixels[..]);
}

fn void set_layered_base_map(Material* material, TextureSlot slot) @private {
    switch (material.kind) {
        case BASIC: material.basic.map = slot;
        case STANDARD: material.standard.base_color_map = slot;
        case TOON: material.toon.map = slot;
        case PHYSICAL: material.physical.standard.base_color_map = slot;
        case CUSTOM:
    }
}

fn void test_layered_mapped_coverage_and_masked_holes_preserve_each_material_family() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    TextureId coverage = add_layered_alpha_map(&fixture, 64, 192)!!;
    TextureId holes = add_layered_alpha_map(&fixture, 0, 255)!!;
    foreach (kind : (MaterialKind[4]){ BASIC, STANDARD, TOON, PHYSICAL }) {
        LayeredScene target = create_layered_scene(&fixture)!!;
        defer scene::destroy_scene(&target.scene);
        target.scene.ambient_color = { 1, 1, 1 };
        target.scene.ambient_intensity = 1;
        LayeredView view = create_layered_view(&fixture)!!;
        defer destroy_layered_view(&fixture, &view);
        MaterialCommon mask_common = material::MATERIAL_COMMON_DEFAULT;
        mask_common.alpha_mode = AlphaMode.MASK;
        mask_common.double_sided = true;
        mask_common.alpha_cutoff = 0.5f;
        MaterialId mask = fixture.assets.add_material(material::basic({
            .color = { 0, 1, 0, 1 },
            .map = material::texture_slot(holes, asset::SAMPLER_NEAREST),
        }, mask_common))!!;
        GeometryId mask_geometry = add_layered_row_geometry(&fixture, LayeredMaterialPath.MESH, 0.75f)!!;
        target.scene.add_mesh(mask_geometry, mask)!!;
        MaterialId blue = add_layered_basic(&fixture, { 0, 0, 1, 0.5f })!!;
        target.scene.add_mesh(add_layered_row_geometry(&fixture, LayeredMaterialPath.MESH, 0.5f)!!, blue)!!;
        MaterialId front = add_layered_row_material(&fixture, { .kind = kind, .path = MESH })!!;
        set_layered_base_map(&fixture.assets.material(front).data,
            material::texture_slot(coverage, asset::SAMPLER_NEAREST));
        fixture.assets.mark_material_dirty(front);
        target.scene.add_mesh(add_layered_row_geometry(&fixture, LayeredMaterialPath.MESH, 0.875f)!!, front)!!;
        Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(pixels);
        uint[] captured = read_layered_depth(&fixture, &view, 0)!!;
        defer free(captured);
        uint[] second = read_layered_depth(&fixture, &view, 1)!!;
        defer free(second);
        for (uint y = LAYERED_INTERIOR_BEGIN; y < LAYERED_INTERIOR_END; y++) {
            for (uint x = LAYERED_INTERIOR_BEGIN; x < LAYERED_INTERIOR_END; x++) {
                if (x + 2 >= LAYERED_IMAGE_SIZE / 2 && x < LAYERED_IMAGE_SIZE / 2 + 2) continue;
                bool masked = x >= LAYERED_IMAGE_SIZE / 2;
                transparency_fixtures::Color behind = masked ? (transparency_fixtures::Color){ 0, 1, 0 }
                  : transparency_fixtures::compose_over(
                    behind: transparency_fixtures::PLANAR_BACKGROUND,
                    radiance: { 0, 0, 1 },
                    coverage: 0.5,
                );
                double alpha = LAYERED_ROW_COVERAGE * (masked ? 192.0 : 64.0) / 255;
                transparency_fixtures::Color expected = transparency_fixtures::compose_over(
                    behind: behind,
                    radiance: LAYERED_ROW_RADIANCE,
                    coverage: alpha,
                );
                uint pixel = y * LAYERED_IMAGE_SIZE + x;
                check_layered_color(pixels[pixel], expected);
                assert(captured[pixel] == bitcast(0.875f, uint));
                assert(second[pixel] == (masked ? 0 : bitcast(0.5f, uint)));
            }
        }
    }
    check_validation(&fixture.renderer);
}

fn void test_layered_billboard_exclusions_preserve_opaque_mask_and_positive_transmission_behavior() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    MaterialCommon common = material::MATERIAL_COMMON_DEFAULT;
    MaterialId opaque = fixture.assets.add_material(material::basic(common: common))!!;
    common.alpha_mode = AlphaMode.MASK;
    MaterialId masked = fixture.assets.add_material(material::basic(common: common))!!;
    common.alpha_mode = AlphaMode.BLEND;
    PhysicalParams params = material::PHYSICAL_PARAMS_DEFAULT;
    params.transmission = 1;
    MaterialId transmission = fixture.assets.add_material(material::physical(params, common))!!;
    foreach (material : (MaterialId[3]){ opaque, masked, transmission }) {
        LayeredScene target = create_layered_scene(&fixture)!!;
        defer scene::destroy_scene(&target.scene);
        LayeredView view = create_layered_view(&fixture)!!;
        defer destroy_layered_view(&fixture, &view);
        add_layered_row_node(
            fixture: &fixture,
            target: &target,
            material: material,
            path: LayeredMaterialPath.BILLBOARD,
        )!!;
        Vec4[] pixels = render_layered_pixels(&fixture, &target, &view)!!;
        defer free(pixels);
        check_layered_interior(pixels, transparency_fixtures::PLANAR_BACKGROUND);
        assert(fixture.renderer.stats.dangling_refs == 1);
        assert(fixture.renderer.view_stats(view.view)!!.transparency.capture_passes == 0);
    }
    check_validation(&fixture.renderer);
}
