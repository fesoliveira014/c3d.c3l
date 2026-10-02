module c3d::test::impostor;

import c3d;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::render @public;
import c3d::scene;
import std::math;

fn void test_impostor_desc_limits() @test {
    render::ImpostorLayout layout = render::impostor_layout(render::IMPOSTOR_DESC_DEFAULT)!!;
    assert(layout.width == 1024 && layout.height == 2048 && layout.bytes == 8 * 1024 * 1024 && layout.usable == 126);
    foreach (uint frames : { 0u, 1u, 3u, 64u }) {
        assert(@catch(render::impostor_layout({ .frames_per_side = frames, .cell_size = 128 })) == c3d::INVALID_ARGUMENT);
    }
    foreach (uint cell : { 0u, 1u, 2u, 3u, uint::max }) {
        assert(@catch(render::impostor_layout({ .frames_per_side = 8, .cell_size = cell })) == c3d::INVALID_ARGUMENT);
    }
    foreach (uint frames : { 2u, 4u, 8u, 16u, 32u }) {
        layout = render::impostor_layout({ .frames_per_side = frames, .cell_size = 4 })!!;
        assert(layout.width == frames * 4 && layout.usable == 2);
    }
}

fn void test_impostor_gutters_preserve_cell_ownership() @test {
    render::ImpostorDesc desc = { .frames_per_side = 2, .cell_size = 4 };
    char[8 * 16 * 4] atlas;
    char[16] red = { 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0 };
    char[16] green = { 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0 };
    ushort[16] normals;
    float[4] depth = { 0.5f, 0.5f, 0.5f, 0.5f };
    char[][2] colors = { red[..], green[..] };
    foreach (uint frame, color : colors) {
        render::pack_impostor_frame(
            atlas: atlas[..],
            desc: desc,
            frame: frame,
            color: color,
            normal: normals[..],
            depth: depth[..],
        );
    }
    for (uint y = 0; y < 4; y++) {
        for (uint x = 0; x < 8; x++) {
            char* pixel = &atlas[(y * 8 + x) * 4];
            assert(pixel[0] == (x < 4 ? 255 : 0));
            assert(pixel[1] == (x < 4 ? 0 : 255));
            assert(pixel[2] == 0 && pixel[3] == 255);
        }
    }
}

fn void test_impostor_padding_preserves_coverage_and_cell_bounds() @test {
    render::ImpostorDesc desc = { .frames_per_side = 2, .cell_size = 4 };
    char[8 * 16 * 4] atlas;
    usz color_offset = (1 * 8 + 1) * 4;
    usz surface_offset = color_offset + 8 * 8 * 4;
    char[4] color = { 20, 40, 80, 255 };
    atlas[color_offset:4] = color[..];
    render::PackedImpostorSurface surface = render::pack_impostor_surface({
        .normal = render::impostor_frame_direction(0, 2), .roughness = 0.4f, .depth = 0.5f, .covered = true,
    });
    atlas[surface_offset:4] = surface.surface[..];
    char[8 * 8 * 4] coverage;
    coverage[..] = atlas[:coverage.len];
    usz[4 * 4 * 2] scratch;
    render::dilate_impostor_frame(
        atlas: atlas[..],
        desc: desc,
        frame: 0,
        scratch: scratch[..],
    );
    assert(mem::equals((char*)&atlas, (char*)&coverage, coverage.len));
    assert(atlas[surface_offset:4] == surface.surface[..]);
    for (uint y = 0; y < 8; y++) {
        for (uint x = 0; x < 8; x++) {
            usz index = (usz)(8 * 8 + y * 8 + x) * 4;
            if (x < 4 && y < 4) {
                assert(atlas[index] == surface.surface[0] && atlas[index + 1] == surface.surface[1]);
                assert(atlas[index + 2] == surface.surface[2]);
            } else {
                assert(atlas[index:4] == (char[4]){});
            }
        }
    }
    render::dilate_impostor_frame(
        atlas: atlas[..],
        desc: desc,
        frame: 1,
        scratch: scratch[..],
    );
    assert(atlas[(8 * 8 + 1 * 8 + 5) * 4:4] == (char[4]){});
}

fn void test_impostor_installation_is_atomic() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    {
        AssetStore assets = asset::create_asset_store(&tracker, {
            .max_geometries = 1,
            .max_materials = 1,
            .max_textures = asset::BUILTIN_TEXTURE_COUNT + 2,
            .max_samplers = asset::BUILTIN_SAMPLER_COUNT,
        });
        defer asset::destroy_asset_store(&assets);
        Scene scene = scene::create_scene(&tracker, { .max_nodes = 1 });
        defer scene::destroy_scene(&scene);
        GeometryId geometry;
        @pool() {
            Geometry box = geometry::box(
                allocator: tmem,
                width: 1,
                height: 1,
                depth: 1,
            );
            geometry = assets.add_geometry(&box)!!;
        };
        MaterialId material = assets.add_material(material::standard())!!;
        LodPart[2] parts = {
            { .geometry = geometry, .material = material, .local = matrix::IDENTITY4 },
            { .geometry = geometry, .material = material, .local = matrix::IDENTITY4 },
        };
        LodLevel[2] levels = {
            { .first_part = 0, .part_count = 1, .min_screen_size = 0.2f },
            { .first_part = 1, .part_count = 1, .min_screen_size = 0 },
        };
        Node* node = scene.add_lod_group(&assets, { .parts = parts[..], .levels = levels[..] })!!;
        TextureDesc desc = material::texture_2d_desc(8, 16, PixelFormat.RGBA8_UNORM);
        desc.generate_mips = false;
        char[512] pixels;
        TextureId atlas = assets.add_texture(desc, pixels[..])!!;
        Impostor impostor = { .atlas = atlas, .bounds = { .radius = 1 }, .frames_per_side = 2, .cell_size = 4 };
        scene.set_lod_impostor(
            assets: &assets,
            node: node,
            impostor: impostor,
            min_screen_size: 0.02f,
        )!!;
        LodGroupState* state = scene.get(node, LodGroup).state;
        uint revision = state.descriptor_revision;
        assert(state.has_impostor && state.impostor_min_screen_size == 0.02f);
        assert(state.desc.levels[^1].min_screen_size == 0);
        float[scene::MAX_LOD_CHOICES] thresholds;
        uint choices = render::fill_lod_thresholds(state, render::lod_impostor_live(&assets, state), thresholds[..]);
        assert(choices == 3);
        assert(scene::select_lod_level(
            screen_size: 0.019f,
            min_screen_sizes: thresholds[:choices],
            previous: 0,
            history_valid: false,
        ) == 2);
        assert(scene::select_lod_level(
            screen_size: 0.021f,
            min_screen_sizes: thresholds[:choices],
            previous: 0,
            history_valid: false,
        ) == 1);
        for (uint fault_case = 0; fault_case < 8; fault_case++) {
            Impostor invalid = impostor;
            float threshold = 0.02f;
            TextureDesc original = assets.texture(atlas).desc;
            switch (fault_case) {
                case 0: assets.texture(atlas).desc.width++;
                case 1: assets.texture(atlas).desc.format = PixelFormat.RGBA8_SRGB;
                case 2: assets.texture(atlas).desc.mip_levels = 2;
                case 3: threshold = 0;
                case 4: threshold = 0.2f;
                case 5: invalid.bounds.radius = 0.5f;
                case 6: invalid.bounds.center.x = bitcast(0x7fc00000u, float);
                case 7: invalid.cell_size = uint::max;
            }
            assert(@catch(scene.set_lod_impostor(
                assets: &assets,
                node: node,
                impostor: invalid,
                min_screen_size: threshold,
            )) == c3d::INVALID_ARGUMENT);
            assets.texture(atlas).desc = original;
            assert(state.descriptor_revision == revision && state.impostor_min_screen_size == 0.02f);
        }
        scene.clear_lod_impostor(node);
        assert(!state.has_impostor && assets.textures.is_live(atlas));
        choices = render::fill_lod_thresholds(state, render::lod_impostor_live(&assets, state), thresholds[..]);
        assert(choices == 2 && thresholds[1] == 0);
        LodEffects effects = state.effects;
        effects.sway = { .direction = { 1, 0, 0 }, .amplitude = 0.1f, .weight = SwayWeight.VERTEX_ALPHA };
        scene.set_lod_effects(node, effects);
        assert(@catch(scene.set_lod_impostor(
            assets: &assets,
            node: node,
            impostor: impostor,
            min_screen_size: 0.02f,
        )) == c3d::UNSUPPORTED);
        effects.sway.amplitude = 0;
        scene.set_lod_effects(node, effects);
        assets.remove_texture(atlas);
        assert(@catch(scene.set_lod_impostor(
            assets: &assets,
            node: node,
            impostor: impostor,
            min_screen_size: 0.02f,
        )) == c3d::INVALID_ID);
        impostor.atlas = assets.add_texture(desc, pixels[..])!!;
        scene.set_lod_impostor(
            assets: &assets,
            node: node,
            impostor: impostor,
            min_screen_size: 0.02f,
        )!!;
        TextureId live = impostor.atlas;
        state.impostor.atlas = atlas;
        assert(!render::lod_impostor_live(&assets, state));
        choices = render::fill_lod_thresholds(state, false, thresholds[..]);
        assert(scene::select_lod_level(
            screen_size: 0.001f,
            min_screen_sizes: thresholds[:choices],
            previous: 0,
            history_valid: false,
        ) == 1);
        state.impostor.atlas = live;
        scene.remove(node);
        assert(assets.textures.is_live(impostor.atlas));
    }
    assert(!tracker.has_leaks());
}

fn void test_impostor_frame_mapping_and_seams() @test {
    foreach (uint side : { 2u, 8u, 32u }) {
        for (uint index = 0; index < side * side; index++) {
            Vec3 direction = render::impostor_frame_direction(index, side);
            assert(math::abs(direction.length() - 1) < 1e-6f);
            render::ImpostorFrames selected = render::impostor_frames(direction, side);
            check_weights(selected, side);
            uint strongest;
            for (uint weight = 1; weight < 3; weight++) {
                if (selected.weights[weight] > selected.weights[strongest]) strongest = weight;
            }
            Vec3 reconstructed = render::impostor_frame_direction(selected.indices[strongest], side);
            assert(direction.distance(reconstructed) < 1e-5f);
        }
        Vec3[10] directions = {
            { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 },
            { 1, 0, -1 }, { -1, 0, -1 }, { 0, 1, -1 }, { 0, -1, -1 },
        };
        foreach (direction : directions) {
            Vec3 before = blended_direction((direction - (Vec3){ 1e-5f, 1e-5f, 0 }).normalize(), side);
            Vec3 after = blended_direction((direction + (Vec3){ 1e-5f, 1e-5f, 0 }).normalize(), side);
            assert(before.distance(after) < 1e-3f);
        }
    }
}

fn void test_impostor_surface_packing() @test {
    Vec3[4] normals = { { 1, 0, 0 }, { 0, 1, 0 }, { 0, 0, 1 }, ((Vec3){ 1, 2, -3 }).normalize() };
    foreach (normal : normals) foreach (float scalar : { 0.0f, 0.5f, 1.0f }) {
        render::PackedImpostorSurface packed = render::pack_impostor_surface({
            .color = { scalar, 0.25f, 1 },
            .normal = normal,
            .roughness = scalar,
            .depth = scalar,
            .covered = true,
        });
        Vec2 octahedral = { (float)packed.surface[0], (float)packed.surface[1] };
        Vec3 decoded = render::decode_octahedral(octahedral * (2.0f / 255) - 1);
        assert(decoded.dot(normal) >= math::cos(math::deg_to_rad(2.0f)));
        assert(math::abs((float)packed.color[0] / 255 - scalar) <= 1.0f / 255);
        assert(math::abs((float)packed.surface[2] / 255 - scalar) <= 1.0f / 255);
        assert(math::abs((float)packed.surface[3] / 255 - scalar) <= 1.0f / 255);
        assert(packed.color[3] == 255);
    }
    assert(render::pack_impostor_surface({}).color[3] == 0);
    assert(render::impostor_half(0x3c00) == 1 && render::impostor_half(0xb800) == -0.5f);
    assert(render::impostor_half(0) == 0 && render::impostor_half(1) > 0);
}

fn void check_weights(render::ImpostorFrames selected, uint side) @private {
    float total;
    foreach (uint index, weight : selected.weights) {
        assert(math::is_finite(weight) && weight >= 0 && selected.indices[index] < side * side);
        total += weight;
    }
    assert(math::abs(total - 1) < 1e-6f);
}

fn Vec3 blended_direction(Vec3 direction, uint side) @private {
    render::ImpostorFrames selected = render::impostor_frames(direction, side);
    check_weights(selected, side);
    Vec3 result;
    foreach (uint index, weight : selected.weights) result += render::impostor_frame_direction(selected.indices[index], side) * weight;
    return result.normalize();
}
