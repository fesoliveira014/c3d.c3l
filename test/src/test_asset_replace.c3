module c3d::test::asset_replace;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::io::path;
import std::math;

struct Unchanged @local {
    uint  revision;
    uint  replaced_revision;
    void* source;
    usz   source_length;
}

fn Unchanged remember(AssetHeader* header, void* source, usz source_length) @local {
    return {
        .revision          = header.revision,
        .replaced_revision = header.replaced_revision,
        .source            = source,
        .source_length     = source_length,
    };
}

fn bool is_unchanged(Unchanged before, AssetHeader* header, void* source, usz source_length) @local {
    return header.revision == before.revision
        && header.replaced_revision == before.replaced_revision
        && source == before.source
        && source_length == before.source_length;
}

fn AssetStore create_store(Allocator allocator) @local {
    return asset::create_asset_store(allocator, {
        .max_geometries = 4,
        .max_textures   = 8,
        .max_materials  = 4,
        .max_samplers   = 5,
        .max_models     = 2,
        .max_skeletons  = 4,
        .max_clips      = 4,
        .max_fonts      = 4,
    });
}

fn String fixture_path(String name) @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../fixtures/gltf", name)!!;
}

fn TextureDesc plain_desc(uint width, uint height, PixelFormat format = RGBA8_UNORM) @local {
    TextureDesc desc = material::texture_2d_desc(width, height, format);
    desc.generate_mips = false;
    return desc;
}

fn void test_replace_texture_keeps_identity_and_advances_once() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        char[16] first = { [0..15] = 7 };
        TextureId texture = assets.add_texture(plain_desc(2, 2), first[..], "t")!!;
        char[64] second = { [0..63] = 9 };
        assets.replace_texture(texture, plain_desc(4, 4), second[..])!!;
        second[0] = 1;

        TextureAsset* record = assets.texture(texture);
        assert(c3d::same_id(assets.find_texture("t")!!, texture));
        assert(record.header.revision == 2 && record.header.replaced_revision == 2);
        assert(record.desc.width == 4 && record.desc.height == 4);
        assert(record.pixels.len == 64 && record.pixels[0] == 9 && record.pixels[63] == 9);
        assert(record.pixels.ptr != &second);

        assets.mark_texture_dirty(texture);
        assert(record.header.revision == 3 && record.header.replaced_revision == 2);
    }

    assert(!tracker.has_leaks());
}

fn void test_replace_texture_rejects_like_add() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        char[16] pixels = { [0..15] = 7 };
        TextureId texture = assets.add_texture(plain_desc(2, 2), pixels[..])!!;
        TextureAsset* record = assets.texture(texture);
        Unchanged before = remember(&record.header, record.pixels.ptr, record.pixels.len);

        TextureDesc invalid = material::texture_2d_desc(2, 2, R16_UINT);
        assert(@catch(assets.replace_texture(texture, invalid, pixels[..])) == c3d::INVALID_ARGUMENT);
        assert(is_unchanged(before, &record.header, record.pixels.ptr, record.pixels.len));
        assert(record.desc.format == RGBA8_UNORM);
    }

    assert(!tracker.has_leaks());
}

fn void test_replace_texture_refuses_structural_change() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        char[16] pixels = { [0..15] = 7 };
        TextureId texture = assets.add_texture(plain_desc(2, 2), pixels[..])!!;
        TextureAsset* record = assets.texture(texture);
        Unchanged before = remember(&record.header, record.pixels.ptr, record.pixels.len);

        TextureDesc cube = plain_desc(2, 2);
        cube.is_cube = true;
        TextureDesc layered = plain_desc(2, 2);
        layered.layers = 2;
        TextureDesc integer = plain_desc(2, 2, R16_UINT);
        TextureDesc storage = plain_desc(2, 2);
        storage.storage = true;
        TextureDesc[4] candidates = { cube, layered, integer, storage };
        foreach (desc : candidates) {
            assert(@catch(assets.replace_texture(texture, desc, pixels[..])) == c3d::INCOMPATIBLE_STRUCTURE);
            assert(is_unchanged(before, &record.header, record.pixels.ptr, record.pixels.len));
        }
    }

    assert(!tracker.has_leaks());
}

fn void test_replace_texture_switches_source_form() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        char[16] base = { [0..15] = 1 };
        char[4] tail = { [0..3] = 2 };
        TextureId texture = assets.add_texture(plain_desc(2, 2), base[..])!!;
        TextureAsset* record = assets.texture(texture);

        TextureDesc with_mips = plain_desc(2, 2);
        with_mips.mip_levels = 2;
        TextureMipData[2] levels = {
            { .mip = 0, .layer = 0, .bytes = base[..] },
            { .mip = 1, .layer = 0, .bytes = tail[..] },
        };
        assets.replace_texture_mips(texture, with_mips, levels[..])!!;
        assert(record.source_kind == SUPPLIED_MIPS && record.supplied_mips.len == 2 && !record.pixels.len);
        assert(record.header.revision == 2);

        assets.replace_texture(texture, plain_desc(2, 2), base[..])!!;
        assert(record.source_kind == MIP_ZERO && record.pixels.len == 16 && !record.supplied_mips.len);
        assert(record.header.revision == 3 && record.header.replaced_revision == 3);
    }

    assert(!tracker.has_leaks());
}

fn void test_replace_texture_owned_adopts_only_on_success() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        char[16] initial = { [0..15] = 1 };
        TextureId texture = assets.add_texture(plain_desc(2, 2), initial[..])!!;
        TextureAsset* record = assets.texture(texture);

        char[] rejected = alloc::new_array(&tracker, char, 16);
        TextureDesc cube = plain_desc(2, 2);
        cube.is_cube = true;
        assert(@catch(assets.replace_texture_owned(texture, cube, rejected)) == c3d::INCOMPATIBLE_STRUCTURE);
        assert(record.pixels.ptr != rejected.ptr);
        alloc::free(&tracker, rejected.ptr);

        char[] adopted = alloc::new_array(&tracker, char, 64);
        assets.replace_texture_owned(texture, plain_desc(4, 4), adopted)!!;
        assert(record.pixels.ptr == adopted.ptr && record.pixels.len == 64);
    }

    assert(!tracker.has_leaks());
}

fn Geometry quad(Allocator allocator) @local {
    return geometry::plane(allocator, 1, 1);
}

fn Geometry grid(Allocator allocator) @local {
    return geometry::plane(allocator, 2, 2, 4, 4);
}

fn void test_replace_geometry_refreshes_counts_and_trees() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        Geometry first = quad(tmem);
        GeometryId id = assets.add_geometry(&first, "g")!!;
        GeometryAsset* record = assets.geometry(id);
        assert(assets.triangle_bvh(id)!!.primitives.len == 2);

        Geometry next = grid(tmem);
        assets.replace_geometry(id, &next)!!;
        assert(record.vertex_count == next.positions.len && record.index_count == next.indices.len);
        assert(record.header.revision == 2 && record.header.replaced_revision == 2);
        assert(assets.triangles_valid(id)!!);
        assert(assets.triangle_bvh(id)!!.primitives.len == next.indices.len / 3);
        assert(c3d::same_id(assets.find_geometry("g")!!, id));
    }

    assert(!tracker.has_leaks());
}

fn Geometry skinned_triangle(
    Allocator allocator,
    ushort second_joint,
    bool skinned = true,
    Topology topology = TRIANGLES,
    uint targets = 0,
) @local {
    Geometry geometry = {
        .topology  = topology,
        .positions = alloc::new_array(allocator, Vec3, 3),
        .indices   = alloc::new_array(allocator, uint, 3),
    };
    geometry.positions[0] = { 0, 0, 0 };
    geometry.positions[1] = { 1, 0, 0 };
    geometry.positions[2] = { 0, 1, 0 };
    foreach (uint index, &slot : geometry.indices) *slot = index;
    if (skinned) {
        geometry.joints = alloc::new_array(allocator, ushort[<4>], 3);
        geometry.weights = alloc::new_array(allocator, Vec4, 3);
        foreach (&joint : geometry.joints) *joint = { 0, 0, 0, 0 };
        geometry.joints[1] = { second_joint, 0, 0, 0 };
        foreach (&weight : geometry.weights) *weight = { 1, 0, 0, 0 };
    }
    geometry.targets = alloc::new_array(allocator, MorphTarget, targets);
    foreach (&target : geometry.targets) {
        target.position_deltas = alloc::new_array(allocator, Vec3, 3);
    }
    geometry.finalize();
    return geometry;
}

fn void test_replace_geometry_refuses_structural_change() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        Geometry first = skinned_triangle(tmem, 1);
        GeometryId id = assets.add_geometry(&first)!!;
        GeometryAsset* record = assets.geometry(id);
        Unchanged before = remember(&record.header, record.data.positions.ptr, record.data.positions.len);

        Geometry lines = skinned_triangle(tmem, 1, topology: LINES);
        Geometry unskinned = skinned_triangle(tmem, 1, skinned: false);
        Geometry out_of_range = skinned_triangle(tmem, 2);
        Geometry morphed = skinned_triangle(tmem, 1, targets: 1);
        Geometry[4] candidates = { lines, unskinned, out_of_range, morphed };
        foreach (&candidate : candidates) {
            assert(@catch(assets.replace_geometry(id, candidate)) == c3d::INCOMPATIBLE_STRUCTURE);
            assert(is_unchanged(before, &record.header, record.data.positions.ptr, record.data.positions.len));
        }
    }

    assert(!tracker.has_leaks());
}

fn void test_replace_geometry_joint_range_stays_within_add_bound() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        Geometry first = skinned_triangle(tmem, 1);
        GeometryId id = assets.add_geometry(&first)!!;
        GeometryAsset* record = assets.geometry(id);
        assert(record.skin_bounds.joints.len == 2);

        Geometry narrow = skinned_triangle(tmem, 0);
        assets.replace_geometry(id, &narrow)!!;
        assert(record.skin_bounds.joints.len == 1 && record.header.revision == 2);

        Geometry wide = skinned_triangle(tmem, 1);
        assets.replace_geometry(id, &wide)!!;
        assert(record.skin_bounds.joints.len == 2 && record.header.revision == 3);

        Geometry beyond = skinned_triangle(tmem, 2);
        Unchanged before = remember(&record.header, record.data.positions.ptr, record.data.positions.len);
        assert(@catch(assets.replace_geometry(id, &beyond)) == c3d::INCOMPATIBLE_STRUCTURE);
        assert(is_unchanged(before, &record.header, record.data.positions.ptr, record.data.positions.len));
    }

    assert(!tracker.has_leaks());
}

fn void test_replace_geometry_after_cpu_release() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        Geometry first = quad(tmem);
        GeometryId id = assets.add_geometry(&first)!!;
        assets.release_geometry_cpu(id);

        Geometry next = grid(tmem);
        assets.replace_geometry(id, &next)!!;
        GeometryAsset* record = assets.geometry(id);
        assert(assets.triangles_valid(id)!!);
        assert(record.vertex_count == next.positions.len && record.index_count == next.indices.len);
    }

    assert(!tracker.has_leaks());
}

fn void test_replace_material_changes_kind_and_frees_payload() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        char[16] small = { [0..15] = 1 };
        char[32] large = { [0..31] = 2 };
        MaterialId id = assets.add_material(material::custom({}, small[..]), "m")!!;
        MaterialAsset* record = assets.material(id);

        assets.replace_material(id, material::standard());
        assert(record.data.kind == MaterialKind.STANDARD && record.header.revision == 2);

        assets.replace_material(id, material::custom({}, large[..]));
        assert(record.data.kind == MaterialKind.CUSTOM && record.data.custom.param_block.len == 32);
        assert(record.data.custom.param_block.ptr != &large);
        assert(record.header.revision == 3 && record.header.replaced_revision == 3);
    }

    assert(!tracker.has_leaks());
}

fn void test_replace_environment_validates_first() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        EnvironmentId id = assets.add_environment(light::solid_environment({ 0.1f, 0.1f, 0.1f }))!!;
        EnvironmentAsset* record = assets.environment(id);

        assert(@catch(assets.replace_environment(id, light::solid_environment({ -1, 0, 0 }))) == c3d::INVALID_ARGUMENT);
        assert(record.header.revision == 1 && record.header.replaced_revision == 0);

        assets.replace_environment(id, light::solid_environment({ 0.5f, 0.5f, 0.5f }))!!;
        assert(record.header.revision == 2 && record.desc.solid_color.x == 0.5f);
    }

    assert(!tracker.has_leaks());
}

fn FontDesc small_font_desc(uint max_glyphs) @local {
    return {
        .max_glyphs   = max_glyphs,
        .curve_texels = asset::FONT_TEXTURE_WIDTH,
        .band_texels  = 4 * asset::FONT_TEXTURE_WIDTH,
    };
}

fn void test_replace_font_rebuilds_face() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        char[] latin = $embed("../fixtures/fonts/latin.ttf");
        char[] pair = $embed("../fixtures/fonts/pair.ttc");
        FontId font = assets.add_font(latin, small_font_desc(64), "f")!!;
        GlyphPlacement[8] placements;
        assets.place_text(font, "abc", placements[..])!!;
        FontAsset* record = assets.font(font);
        assert(record.glyph_count > 0);
        uint revision = record.header.revision;

        assets.replace_font(font, pair, small_font_desc(32))!!;
        assert(record.glyph_count == 0 && record.desc.max_glyphs == 32);
        assert(record.header.revision == revision + 1 && record.header.replaced_revision == revision + 1);

        char[3] bytes = { 1, 2, 3 };
        Unchanged before = remember(&record.header, record.file.ptr, record.file.len);
        assert(@catch(assets.replace_font(font, bytes[..], small_font_desc(32))) == c3d::ASSET_FORMAT_ERROR);
        assert(is_unchanged(before, &record.header, record.file.ptr, record.file.len));
    }

    assert(!tracker.has_leaks());
}

fn Skeleton make_skeleton(Allocator allocator, int[] parents, float offset) @local {
    Skeleton skeleton = {
        .joint_names  = alloc::new_array(allocator, String, parents.len),
        .parents      = alloc::new_array(allocator, int, parents.len),
        .rest_pose    = alloc::new_array(allocator, Transform, parents.len),
        .inverse_bind = alloc::new_array(allocator, Mat4, parents.len),
    };
    skeleton.parents[..] = parents[..];
    foreach (index, &name : skeleton.joint_names) *name = "joint".copy(allocator);
    foreach (&pose : skeleton.rest_pose) {
        *pose = maths::TRANSFORM_IDENTITY;
        pose.position = { offset, 0, 0 };
    }
    foreach (&matrix : skeleton.inverse_bind) *matrix = matrix::IDENTITY4;
    return skeleton;
}

fn void test_replace_skeleton_refuses_hierarchy_change() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        int[3] chain = { -1, 0, 1 };
        Skeleton first = make_skeleton(&tracker, chain[..], 0);
        SkeletonId id = assets.add_skeleton_owned(&first, "s")!!;
        SkeletonAsset* record = assets.skeleton(id);
        Unchanged before = remember(&record.header, record.data.parents.ptr, record.data.parents.len);

        int[3] siblings = { -1, 0, 0 };
        Skeleton changed = make_skeleton(&tracker, siblings[..], 0);
        assert(@catch(assets.replace_skeleton_owned(id, &changed)) == c3d::INCOMPATIBLE_STRUCTURE);
        assert(is_unchanged(before, &record.header, record.data.parents.ptr, record.data.parents.len));
        asset::free_skeleton(&tracker, &changed);

        Skeleton moved = make_skeleton(&tracker, chain[..], 5);
        assets.replace_skeleton_owned(id, &moved)!!;
        assert(record.data.rest_pose[0].position.x == 5 && record.header.revision == 2);
    }

    assert(!tracker.has_leaks());
}

fn AnimationClip make_clip(
    Allocator allocator,
    String name,
    float duration,
    sz track_count,
    uint[] targets,
    float[] times,
    float[] values,
) @local {
    AnimationClip clip = {
        .name     = name.copy(allocator),
        .duration = duration,
        .tracks   = alloc::new_array(allocator, Track, track_count),
        .targets  = alloc::new_array(allocator, uint, targets.len),
    };
    clip.targets[..] = targets[..];
    foreach (index, &track : clip.tracks) {
        *track = {
            .target        = (uint)index,
            .path          = TargetPath.TRANSLATION,
            .interpolation = Interpolation.LINEAR,
            .times         = alloc::new_array(allocator, float, times.len),
            .values        = alloc::new_array(allocator, float, values.len),
        };
        track.times[..] = times[..];
        track.values[..] = values[..];
    }
    return clip;
}

fn void test_replace_clip_keeps_layout() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_store(&tracker);
        defer asset::destroy_asset_store(&assets);
        Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
        defer scene::destroy_scene(&scene);

        ModelId model = gltf::load_model(&assets, fixture_path("skin.gltf"))!!;
        Node* root = model::instantiate(&assets, &scene, model)!!;
        ModelInstance* instance = scene.get(root, ModelInstance);

        uint[2] targets = { 3, 2 };
        float[2] times = { 0, 1 };
        float[6] values = { 0, 0, 0, 0, 1, 0 };
        AnimationClip first = make_clip(&tracker, "lift", 1, 2, targets[..], times[..], values[..]);
        ClipId id = assets.add_clip_owned(&first, "lift")!!;
        ClipAsset* record = assets.clip(id);
        Unchanged before = remember(&record.header, record.data.tracks.ptr, record.data.tracks.len);

        Animator* animator = anim::add_animator(&scene, root);
        animator.play(&assets, id)!!;
        anim::update(&assets, &scene, 0);

        uint[3] three_targets = { 3, 2, 1 };
        AnimationClip extra_track = make_clip(&tracker, "lift", 1, 3, three_targets[..], times[..], values[..]);
        uint[2] other_targets = { 3, 4 };
        AnimationClip other_table = make_clip(&tracker, "lift", 1, 2, other_targets[..], times[..], values[..]);
        AnimationClip no_duration = make_clip(&tracker, "lift", 0, 2, targets[..], times[..], values[..]);
        AnimationClip[3] rejected = { extra_track, other_table, no_duration };
        foreach (&candidate : rejected) {
            assert(@catch(assets.replace_clip_owned(id, candidate)) == c3d::INCOMPATIBLE_STRUCTURE);
            assert(is_unchanged(before, &record.header, record.data.tracks.ptr, record.data.tracks.len));
            asset::free_clip(&tracker, candidate);
        }

        float[2] new_times = { 0, 2 };
        float[6] new_values = { 0, 0, 0, 0, 10, 0 };
        AnimationClip next = make_clip(&tracker, "lift", 2, 2, targets[..], new_times[..], new_values[..]);
        assets.replace_clip_owned(id, &next)!!;
        assert(record.header.revision == 2 && record.data.duration == 2);

        anim::update(&assets, &scene, 0.5f);
        Node* tip = instance.present_node(3);
        assert(math::abs(tip.local.position.y - 2.5f) < 1e-4f);
    }

    assert(!tracker.has_leaks());
}
