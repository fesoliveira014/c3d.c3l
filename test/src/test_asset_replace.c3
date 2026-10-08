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

        TextureDesc volume = plain_desc(2, 2);
        volume.depth = 2;
        assert(@catch(assets.replace_texture(texture, volume, pixels[..])) == c3d::INCOMPATIBLE_STRUCTURE);
        assert(is_unchanged(before, &record.header, record.pixels.ptr, record.pixels.len));

        char[16 * 2] slab = { [0..31] = 3 };
        TextureId volume_id = assets.add_texture(volume, slab[..])!!;
        TextureDesc deeper = plain_desc(2, 2);
        deeper.depth = 3;
        char[16 * 3] thick = { [0..47] = 4 };
        assets.replace_texture(volume_id, deeper, thick[..])!!;
        assert(assets.texture(volume_id).desc.depth == 3 && assets.texture(volume_id).header.revision == 2);
        assert(@catch(assets.replace_texture(volume_id, plain_desc(2, 2), pixels[..])) == c3d::INCOMPATIBLE_STRUCTURE);
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

struct DocumentVariant @local {
    char   pixel;
    float  shift;
    float  lift;
    float  node_x;
    String clip_name;
    bool   with_clip;
    bool   with_sampler;
    bool   with_extra_texture;
    bool   with_extra_node;
    String document_key;
}

struct ReplaceRefs @local {
    SamplerId  sampler;
    TextureId  texture;
    MaterialId material;
    GeometryId geometry;
    ClipId     clip;
}

struct Revisions @local {
    uint model;
    uint sampler;
    uint texture;
    uint material;
    uint geometry;
    uint clip;
}

fn DocumentVariant base_variant() @local {
    return {
        .pixel        = 1,
        .shift        = 0,
        .lift         = 1,
        .node_x       = 0,
        .clip_name    = "lift",
        .with_clip    = true,
        .with_sampler = true,
        .document_key = "m",
    };
}

fn AssetStore create_model_store(Allocator allocator, uint max_textures = asset::BUILTIN_TEXTURE_COUNT + 3) @local {
    return asset::create_asset_store(allocator, {
        .max_geometries = 2,
        .max_textures   = max_textures,
        .max_materials  = 2,
        .max_samplers   = asset::BUILTIN_SAMPLER_COUNT + 2,
        .max_models     = 2,
        .max_skeletons  = 2,
        .max_clips      = 4,
    });
}

fn char[] numbered_texels(Allocator allocator, char first) @local {
    char[] pixels = alloc::new_array(allocator, char, 16);
    foreach (index, &pixel : pixels) *pixel = first + (char)index;
    return pixels;
}

fn ModelDocument build_model_document(Allocator allocator, DocumentVariant variant) @local {
    ModelDocument document = asset::create_model_document(allocator, variant.document_key, {
        .samplers   = 1,
        .textures   = 2,
        .materials  = 1,
        .geometries = 1,
        .clips      = 1,
    });

    SamplerId sampler = asset::SAMPLER_LINEAR_CLAMP;
    if (variant.with_sampler) {
        SamplerDesc desc = material::sampler_desc(Filter.NEAREST, AddressMode.CLAMP_TO_EDGE, "m_sampler");
        sampler = document.push_sampler(desc, "m#sampler");
    }
    TextureId texture = document.push_texture(
        plain_desc(2, 2),
        numbered_texels(allocator, variant.pixel),
        "m#image/0/srgb",
    );
    StandardParams params = material::STANDARD_PARAMS_DEFAULT;
    params.base_color_map = material::texture_slot(texture: texture, sampler: sampler);
    if (variant.with_extra_texture) {
        TextureId extra = document.push_texture(
            plain_desc(2, 2),
            numbered_texels(allocator, variant.pixel),
            "m#image/1/srgb",
        );
        params.normal_map = material::texture_slot(texture: extra, sampler: sampler);
    }
    params.base_color = { 1, 1, variant.lift * 0.25f, 1 };
    MaterialId surface = document.push_material(material::standard(params), "m#material");

    Geometry geometry = quad(allocator);
    foreach (&position : geometry.positions) position.y += variant.shift;
    geometry.finalize();
    GeometryId mesh = document.push_geometry(&geometry, "m#mesh");

    ModelTemplate* template = &document.template;
    sz node_count = variant.with_extra_node ? 3 : 2;
    template.nodes = alloc::new_array(allocator, NodeTemplate, node_count);
    template.nodes[0] = { .parent = -1, .name = "root".copy(allocator), .local = maths::TRANSFORM_IDENTITY };
    template.nodes[1] = { .parent = 0, .name = "mesh".copy(allocator), .local = maths::TRANSFORM_IDENTITY };
    template.nodes[1].local.position.x = variant.node_x;
    if (variant.with_extra_node) {
        template.nodes[2] = { .parent = 0, .name = "extra".copy(allocator), .local = maths::TRANSFORM_IDENTITY };
    }
    template.meshes = alloc::new_array(allocator, ModelMesh, 1);
    template.meshes[0] = { .node = 1, .geometry = mesh, .material = surface };
    if (variant.with_clip) {
        uint[1] targets = { 1 };
        float[2] times = { 0, 1 };
        float[6] values = { 0, 0, 0, 0, variant.lift, 0 };
        AnimationClip clip = make_clip(allocator, variant.clip_name, 1, 1, targets[..], times[..], values[..]);
        ClipId reference = document.push_clip(&clip, "m#anim/0");
        template.clips = alloc::new_array(allocator, ClipId, 1);
        template.clips[0] = reference;
    }
    return document;
}

fn ReplaceRefs find_parts(AssetStore* assets) @local {
    return {
        .sampler  = assets.find_sampler("m#sampler") ?? (SamplerId){},
        .texture  = assets.find_texture("m#image/0/srgb")!!,
        .material = assets.find_material("m#material")!!,
        .geometry = assets.find_geometry("m#mesh")!!,
        .clip     = assets.find_clip("m#anim/0") ?? (ClipId){},
    };
}

fn Revisions revisions_of(AssetStore* assets, ModelId model, ReplaceRefs refs) @local {
    return {
        .model    = assets.model(model).header.revision,
        .sampler  = refs.sampler.index ? assets.sampler(refs.sampler).header.revision : 0,
        .texture  = assets.texture(refs.texture).header.revision,
        .material = assets.material(refs.material).header.revision,
        .geometry = assets.geometry(refs.geometry).header.revision,
        .clip     = refs.clip.index ? assets.clip(refs.clip).header.revision : 0,
    };
}

fn bool same_revisions(Revisions first, Revisions second) @local {
    return first.model == second.model && first.sampler == second.sampler && first.texture == second.texture
        && first.material == second.material && first.geometry == second.geometry && first.clip == second.clip;
}

fn void test_replace_document_replaces_matches_in_place() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_model_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        ModelDocument first = build_model_document(&tracker, base_variant());
        defer asset::destroy_model_document(&first);
        ModelId model = assets.publish_document(&first)!!;
        ReplaceRefs before = find_parts(&assets);

        DocumentVariant changed = base_variant();
        changed.pixel = 50;
        changed.shift = 2;
        changed.lift = 3;
        ModelDocument next = build_model_document(&tracker, changed);
        defer asset::destroy_model_document(&next);
        ModelReplaceReport report = assets.replace_document(model, &next)!!;

        ReplaceRefs after = find_parts(&assets);
        assert(c3d::same_id(after.sampler, before.sampler) && c3d::same_id(after.texture, before.texture));
        assert(c3d::same_id(after.material, before.material) && c3d::same_id(after.geometry, before.geometry));
        assert(c3d::same_id(after.clip, before.clip));
        assert(c3d::same_id(assets.find_model("m")!!, model));
        assert(report.replaced == 5 && report.added == 0 && report.missing == 0);
        assert(revisions_of(&assets, model, after).model == 2);
        assert(assets.sampler(after.sampler).header.revision == 2);
        assert(assets.texture(after.texture).header.revision == 2);
        assert(assets.material(after.material).header.revision == 2);
        assert(assets.geometry(after.geometry).header.revision == 2);
        assert(assets.clip(after.clip).header.revision == 2);
        assert(assets.model(model).header.replaced_revision == 2);
        assert(assets.texture(after.texture).pixels[0] == 50);
        assert(assets.geometry(after.geometry).data.positions[0].y == changed.shift + quad(tmem).positions[0].y);
        TextureRef bound = assets.material(after.material).data.standard.base_color_map.texture;
        assert(c3d::same_id(bound.asset, before.texture));
        assert(c3d::same_id(assets.model(model).data.meshes[0].geometry, before.geometry));
        assert(!next.textures.len || !next.textures[0].pixels.len);
    }

    assert(!tracker.has_leaks());
}

fn void test_replace_document_adds_and_reports_missing() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_model_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        ModelDocument first = build_model_document(&tracker, base_variant());
        defer asset::destroy_model_document(&first);
        ModelId model = assets.publish_document(&first)!!;
        ReplaceRefs parts = find_parts(&assets);

        uint[1] targets = { 1 };
        float[2] times = { 0, 1 };
        float[6] values = { 0, 0, 0, 0, 1, 0 };
        AnimationClip derived = make_clip(&tracker, "derived", 1, 1, targets[..], times[..], values[..]);
        ClipId retargeted = assets.add_clip_owned(&derived, "m#anim/0#other#additive")!!;

        DocumentVariant changed = base_variant();
        changed.with_clip = false;
        changed.with_sampler = false;
        changed.with_extra_texture = true;
        AssetRef[1] one;
        ModelDocument next = build_model_document(&tracker, changed);
        defer asset::destroy_model_document(&next);
        ModelReplaceReport report = assets.replace_document(model, &next, one[..])!!;

        assert(report.replaced == 3 && report.added == 1 && report.missing == 2);
        assert(one[0].kind == AssetKind.SAMPLER);
        SamplerId reported = { .index = one[0].id.index, .generation = one[0].id.generation };
        assert(c3d::same_id(reported, parts.sampler));
        assert(assets.clips.is_live(parts.clip) && assets.clips.is_live(retargeted));
        assert(assets.samplers.is_live(parts.sampler));
        assert(assets.find_texture("m#image/1/srgb")!!.index != 0);

        ModelDocument third = build_model_document(&tracker, changed);
        defer asset::destroy_model_document(&third);
        ModelReplaceReport again = assets.replace_document(model, &third, {})!!;
        assert(again.missing == 2 && again.added == 0 && again.replaced == 4);
    }

    assert(!tracker.has_leaks());
}

fn void test_replace_document_refuses_structure() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_model_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        ModelDocument first = build_model_document(&tracker, base_variant());
        defer asset::destroy_model_document(&first);
        ModelId model = assets.publish_document(&first)!!;
        ReplaceRefs parts = find_parts(&assets);
        Revisions before = revisions_of(&assets, model, parts);

        DocumentVariant changed = base_variant();
        changed.with_extra_node = true;
        changed.pixel = 9;
        ModelDocument next = build_model_document(&tracker, changed);
        defer asset::destroy_model_document(&next);
        char* pixels = next.textures[0].pixels.ptr;
        assert(@catch(assets.replace_document(model, &next)) == c3d::INCOMPATIBLE_STRUCTURE);

        assert(same_revisions(revisions_of(&assets, model, parts), before));
        assert(next.textures.len == 1 && next.textures[0].pixels.ptr == pixels);
        assert(next.template.nodes.len == 3 && next.geometries.len == 1);
        assert(assets.model(model).header.replaced_revision == 0);
    }

    assert(!tracker.has_leaks());
}

fn void test_replace_rejects_unset_template_references() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_model_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        ModelDocument first = build_model_document(&tracker, base_variant());
        defer asset::destroy_model_document(&first);
        ModelId model = assets.publish_document(&first)!!;
        ReplaceRefs parts = find_parts(&assets);
        Revisions before = revisions_of(&assets, model, parts);
        ClipId[] clips = mem::@tclone_slice(assets.model(model).data.clips);

        ModelDocument unset_geometry = build_model_document(&tracker, base_variant());
        defer asset::destroy_model_document(&unset_geometry);
        unset_geometry.template.meshes[0].geometry = {};
        assert(@catch(assets.replace_document(model, &unset_geometry)) == c3d::INVALID_ARGUMENT);

        ModelDocument unset_clip = build_model_document(&tracker, base_variant());
        defer asset::destroy_model_document(&unset_clip);
        unset_clip.template.clips[0] = {};
        assert(@catch(assets.replace_document(model, &unset_clip)) == c3d::INVALID_ARGUMENT);

        assert(same_revisions(revisions_of(&assets, model, parts), before));
        ClipId[] after = assets.model(model).data.clips;
        assert(after.len == clips.len);
        foreach (index, clip : after) assert(c3d::same_id(clip, clips[index]));
    }

    assert(!tracker.has_leaks());
}

fn void test_replace_document_refuses_renamed_clip() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_model_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        ModelDocument first = build_model_document(&tracker, base_variant());
        defer asset::destroy_model_document(&first);
        ModelId model = assets.publish_document(&first)!!;
        ReplaceRefs parts = find_parts(&assets);
        Revisions before = revisions_of(&assets, model, parts);

        DocumentVariant changed = base_variant();
        changed.clip_name = "other";
        ModelDocument next = build_model_document(&tracker, changed);
        defer asset::destroy_model_document(&next);
        assert(@catch(assets.replace_document(model, &next)) == c3d::INCOMPATIBLE_STRUCTURE);
        assert(same_revisions(revisions_of(&assets, model, parts), before));
        assert(assets.clip(parts.clip).data.name == "lift");
    }

    assert(!tracker.has_leaks());
}

fn void test_replace_document_checks_keys() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_model_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        ModelDocument first = build_model_document(&tracker, base_variant());
        defer asset::destroy_model_document(&first);
        ModelId model = assets.publish_document(&first)!!;
        ReplaceRefs parts = find_parts(&assets);
        Revisions before = revisions_of(&assets, model, parts);

        DocumentVariant other_key = base_variant();
        other_key.document_key = "n";
        ModelDocument wrong_document = build_model_document(&tracker, other_key);
        defer asset::destroy_model_document(&wrong_document);
        assert(@catch(assets.replace_document(model, &wrong_document)) == c3d::INVALID_ARGUMENT);

        ModelDocument unkeyed = build_model_document(&tracker, base_variant());
        defer asset::destroy_model_document(&unkeyed);
        asset::free_string(&tracker, unkeyed.textures[0].key);
        unkeyed.textures[0].key = {};
        assert(@catch(assets.replace_document(model, &unkeyed)) == c3d::INVALID_ARGUMENT);

        ModelDocument crossed = build_model_document(&tracker, base_variant());
        defer asset::destroy_model_document(&crossed);
        asset::free_string(&tracker, crossed.geometries[0].key);
        crossed.geometries[0].key = "m#material".copy(&tracker);
        assert(@catch(assets.replace_document(model, &crossed)) == c3d::INVALID_ARGUMENT);

        assert(same_revisions(revisions_of(&assets, model, parts), before));
    }

    assert(!tracker.has_leaks());
}

fn void test_replace_document_checks_capacity_first() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_model_store(&tracker, asset::BUILTIN_TEXTURE_COUNT + 1);
        defer asset::destroy_asset_store(&assets);

        ModelDocument first = build_model_document(&tracker, base_variant());
        defer asset::destroy_model_document(&first);
        ModelId model = assets.publish_document(&first)!!;
        ReplaceRefs parts = find_parts(&assets);
        Revisions before = revisions_of(&assets, model, parts);

        DocumentVariant changed = base_variant();
        changed.with_extra_texture = true;
        changed.shift = 1;
        ModelDocument next = build_model_document(&tracker, changed);
        defer asset::destroy_model_document(&next);
        assert(@catch(assets.replace_document(model, &next)) == c3d::CAPACITY_EXCEEDED);
        assert(same_revisions(revisions_of(&assets, model, parts), before));
    }

    assert(!tracker.has_leaks());
}

fn void test_replace_document_keeps_instance_copies() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_model_store(&tracker);
        defer asset::destroy_asset_store(&assets);
        Scene scene = scene::create_scene(mem, { .max_nodes = 16 });
        defer scene::destroy_scene(&scene);

        ModelDocument first = build_model_document(&tracker, base_variant());
        defer asset::destroy_model_document(&first);
        ModelId model = assets.publish_document(&first)!!;
        Node* root = model::instantiate(&assets, &scene, model)!!;
        ModelInstance* instance = scene.get(root, ModelInstance);
        ReplaceRefs parts = find_parts(&assets);

        DocumentVariant changed = base_variant();
        changed.node_x = 4;
        changed.shift = 2;
        ModelDocument next = build_model_document(&tracker, changed);
        defer asset::destroy_model_document(&next);
        assets.replace_document(model, &next)!!;

        assert(instance.present_node(1).local.position.x == 0);
        assert(c3d::same_id(assets.model(model).data.meshes[0].geometry, parts.geometry));
        assert(assets.geometry(parts.geometry).data.positions[0].y > 1);
        Node* fresh = model::instantiate(&assets, &scene, model)!!;
        assert(scene.get(fresh, ModelInstance).present_node(1).local.position.x == 4);
    }

    assert(!tracker.has_leaks());
}

fn NodeTemplate named_node(Allocator allocator, String name, int parent) @local {
    return { .parent = parent, .name = name.copy(allocator), .local = maths::TRANSFORM_IDENTITY };
}

fn ModelTemplate single_mesh_template(
    Allocator allocator,
    String root_name,
    GeometryId geometry,
    MaterialId material,
) @local {
    ModelTemplate template = {
        .nodes  = alloc::new_array(allocator, NodeTemplate, 2),
        .meshes = alloc::new_array(allocator, ModelMesh, 1),
    };
    template.nodes[0] = named_node(allocator, root_name, -1);
    template.nodes[1] = named_node(allocator, "mesh", 0);
    template.meshes[0] = { .node = 1, .geometry = geometry, .material = material };
    return template;
}

fn void test_replace_model_owned_requires_signature() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = create_model_store(&tracker);
        defer asset::destroy_asset_store(&assets);

        Geometry geometry = quad(tmem);
        GeometryId mesh = assets.add_geometry(&geometry)!!;
        MaterialId first = assets.add_material(material::standard(material::STANDARD_PARAMS_DEFAULT))!!;
        MaterialId second = assets.add_material(material::standard(material::STANDARD_PARAMS_DEFAULT))!!;
        ModelTemplate original = single_mesh_template(&tracker, "root", mesh, first);
        ModelId model = assets.add_model_owned(&original, "t")!!;

        ModelTemplate rebound = single_mesh_template(&tracker, "root", mesh, second);
        assert(@catch(assets.replace_model_owned(model, &rebound)) == c3d::INCOMPATIBLE_STRUCTURE);
        assert(assets.model(model).header.revision == 1);
        asset::free_model_template(&tracker, &rebound);

        ModelTemplate renamed = single_mesh_template(&tracker, "renamed", mesh, first);
        assets.replace_model_owned(model, &renamed)!!;
        assert(assets.model(model).header.revision == 2);
        assert(assets.model(model).data.nodes[0].name == "renamed");
    }

    assert(!tracker.has_leaks());
}

fn String model_key_directory() @local {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../fixtures/gltf")!!;
}

fn AssetRef[] snapshot_keys(AssetStore* assets) @local {
    AssetRef[] refs = alloc::new_array(tmem, AssetRef, (sz)assets.keys.len());
    usz next;
    foreach (key : assets.keys.tkeys()) refs[next++] = assets.keys.get(key)!!;
    return refs;
}

fn bool same_ref_set(AssetRef[] first, AssetRef[] second) @local {
    if (first.len != second.len) return false;
    foreach (ref : first) {
        bool found;
        foreach (other : second) {
            if (ref.kind == other.kind && c3d::same_id(ref.id, other.id)) found = true;
        }
        if (!found) return false;
    }
    return true;
}

fn void test_gltf_replace_model_round_trip() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = asset::create_asset_store(&tracker, asset::default_asset_store_desc());
        defer asset::destroy_asset_store(&assets);

        String path = fixture_path("skin.gltf");
        ModelId model = gltf::load_model(&assets, path)!!;
        @pool() {
            AssetRef[] before = snapshot_keys(&assets);
            uint parts;
            foreach (key : assets.keys.tkeys()) {
                if (key.starts_with(path) && key.len > path.len) parts++;
            }

            ModelReplaceReport report = gltf::replace_model(&assets, model, path)!!;
            assert(report.replaced == parts && report.added == 0 && report.missing == 0);
            assert(same_ref_set(before, snapshot_keys(&assets)));
            assert(assets.model(model).header.revision == 2);
        };
    }

    assert(!tracker.has_leaks());
}

fn void test_gltf_replace_model_failed_decode_changes_nothing() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    {
        AssetStore assets = asset::create_asset_store(&tracker, asset::default_asset_store_desc());
        defer asset::destroy_asset_store(&assets);

        String path = fixture_path("skin.gltf");
        ModelId model = gltf::load_model(&assets, path)!!;
        GeometryId geometry = assets.model(model).data.meshes[0].geometry;

        char[3] garbage = { 1, 2, 3 };
        fault excuse = @catch(gltf::replace_model_memory(&assets, model, garbage[..], model_key_directory(), path));
        assert(excuse == c3d::ASSET_FORMAT_ERROR);
        assert(assets.model(model).header.revision == 1);
        assert(assets.geometry(geometry).header.revision == 1);
    }

    assert(!tracker.has_leaks());
}
