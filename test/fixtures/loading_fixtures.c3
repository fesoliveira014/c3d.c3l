module c3d::test::loading_fixtures;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::scene;
import std::core::dstring;
import std::core::string;
import std::math;

<* Version of the deterministic loading corpus. *>
const uint FIXTURE_VERSION = 1;

<* Seed of the generated texture corpus shared by CPU and Vulkan preparation checks. *>
const uint PREPARATION_IMAGE_SEED = 0x2545f491;
const uint PREPARATION_RANDOM_MULTIPLIER @local = 1664525; // reproduces the existing texture corpus
const uint PREPARATION_RANDOM_INCREMENT @local = 1013904223;

<*
 Generate a triangle model with a configurable node chain.
 @require node_count > 0
*>
fn char[] small_model_gltf(Allocator allocator, uint node_count = 2) {
    DString json;
    json.init(allocator);
    defer json.free();
    json.append_string(`{"asset":{"version":"2.0"},"scene":0,"scenes":[{"nodes":[0]}],"nodes":[`);
    for (uint node = 0; node < node_count; node++) {
        if (node) json.append_char(',');
        json.appendf(`{"name":"node_%s"`, node)!!;
        if (node + 1 < node_count) {
            json.appendf(`,"children":[%s]`, node + 1)!!;
        } else {
            json.append_string(`,"mesh":0`);
        }
        json.append_char('}');
    }
    json.append_string(
        str: `],"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],`
             `"buffers":[{"byteLength":36,"uri":"data:application/octet-stream;base64,`
             `AAAAAAAAAAAAAAAAAACAPwAAAAAAAAAAAAAAAAAAgD8AAAAA"}],`
             `"bufferViews":[{"buffer":0,"byteLength":36}],`
             `"accessors":[{"bufferView":0,"componentType":5126,"count":3,`
             `"type":"VEC3","min":[0,0,0],"max":[1,1,0]}]}`,
    );
    return (char[])json.copy_str(allocator);
}

fn Geometry triangle_geometry(Allocator allocator) @local {
    Geometry geometry = {
        .topology = Topology.TRIANGLES,
        .positions = alloc::new_array(allocator, Vec3, 3),
        .indices = alloc::new_array(allocator, uint, 3),
    };
    geometry.positions[0] = { 0, 0, 0 };
    geometry.positions[1] = { 1, 0, 0 };
    geometry.positions[2] = { 0, 1, 0 };
    geometry.indices[..] = { 0, 1, 2 }[..];
    geometry.finalize();
    return geometry;
}

<* Generate every model entry kind and nested structural inventory. *>
fn ModelDocument full_model_document(Allocator allocator, String key) {
    @pool() {
        ModelDocument document = asset::create_model_document(allocator, key, {
            .samplers = 1, .textures = 1, .materials = 1, .geometries = 2, .skeletons = 1, .clips = 1,
        });
        SamplerId sampler = document.push_sampler(
            desc: material::sampler_desc(Filter.NEAREST, AddressMode.CLAMP_TO_EDGE),
            key: string::tformat("%s#sampler", key),
        );
        char[] pixels = alloc::new_array(allocator, char, 16);
        foreach (index, &pixel : pixels) *pixel = (char)(index * 13);
        TextureId texture = document.push_texture(
            desc: material::texture_2d_desc(2, 2, RGBA8_UNORM),
            pixels: pixels,
            key: string::tformat("%s#texture", key),
        );
        StandardParams params = material::STANDARD_PARAMS_DEFAULT;
        params.base_color_map = material::texture_slot(texture: texture, sampler: sampler);
        MaterialId material = document.push_material(material::standard(params), string::tformat("%s#material", key));
        Geometry skinned = triangle_geometry(allocator);
        skinned.joints = alloc::new_array(allocator, ushort[<4>], 3);
        skinned.weights = alloc::new_array(allocator, Vec4, 3);
        foreach (index, &joints : skinned.joints) {
            *joints = { 0, 1, 600, 0 };
            skinned.weights[index] = { 0.5, 0.5, 0, 0 };
        }
        skinned.targets = alloc::new_array(allocator, MorphTarget, 1);
        skinned.targets[0] = { .position_deltas = alloc::new_array(allocator, Vec3, 3), .name = "raise".copy(allocator) };
        foreach (&delta : skinned.targets[0].position_deltas) *delta = { 0, 0, 0.25 };
        skinned.channels = alloc::new_array(allocator, MorphChannel, 1);
        skinned.channels[0] = { .name = "raise".copy(allocator), .first_target = 0, .full_weights = alloc::new_array(allocator, float, 1) };
        skinned.channels[0].full_weights[0] = 1;
        GeometryId geometry = document.push_geometry(&skinned, string::tformat("%s#geometry", key));
        Geometry rigid = triangle_geometry(allocator);
        GeometryId lod_geometry = document.push_geometry(&rigid, string::tformat("%s#lod_geometry", key));
        Skeleton skeleton = {
            .joint_names = alloc::new_array(allocator, String, 2),
            .parents = alloc::new_array(allocator, int, 2),
            .rest_pose = alloc::new_array(allocator, Transform, 2),
            .inverse_bind = alloc::new_array(allocator, Mat4, 2),
        };
        skeleton.joint_names[0] = "root".copy(allocator);
        skeleton.joint_names[1] = "joint".copy(allocator);
        skeleton.parents[..] = { -1, 0 }[..];
        foreach (&pose : skeleton.rest_pose) *pose = maths::TRANSFORM_IDENTITY;
        foreach (&inverse : skeleton.inverse_bind) *inverse = matrix::IDENTITY4;
        SkeletonId skeleton_id = document.push_skeleton(&skeleton, string::tformat("%s#skeleton", key));
        AnimationClip clip = {
            .name = "motion".copy(allocator), .duration = 1,
            .targets = alloc::new_array(allocator, uint, 2),
            .tracks = alloc::new_array(allocator, Track, 2),
            .events = alloc::new_array(allocator, ClipEvent, 2),
        };
        clip.targets[..] = { 0, 1 }[..];
        foreach (index, &track : clip.tracks) {
            *track = { .target = (uint)index, .path = TargetPath.TRANSLATION, .interpolation = Interpolation.LINEAR,
              .times = alloc::new_array(allocator, float, 2), .values = alloc::new_array(allocator, float, 6) };
            track.times[..] = { 0.0f, 1.0f }[..];
            track.values[3] = (float)index + 0.5;
        }
        clip.events[0] = { .time = 0.25, .id = 1 };
        clip.events[1] = { .time = 0.75, .id = 2 };
        ClipId clip_id = document.push_clip(&clip, string::tformat("%s#clip", key));
        ModelTemplate* template = &document.template;
        template.nodes = alloc::new_array(allocator, NodeTemplate, 3);
        foreach (index, &node : template.nodes) {
            *node = { .parent = index ? 0 : -1, .name = string::format(allocator, "node_%s", index), .local = maths::TRANSFORM_IDENTITY };
        }
        template.meshes = alloc::new_array(allocator, ModelMesh, 1);
        template.meshes[0] = { .node = 1, .geometry = geometry, .material = material };
        template.skins = alloc::new_array(allocator, ModelSkin, 1);
        template.skins[0] = { .mesh_node = 1, .skeleton = skeleton_id, .joint_nodes = alloc::new_array(allocator, uint, 2) };
        template.skins[0].joint_nodes[..] = { 0, 1 }[..];
        template.clips = alloc::new_array(allocator, ClipId, 1);
        template.clips[0] = clip_id;
        template.lod_groups = alloc::new_array(allocator, ModelLodGroup, 1);
        template.lod_groups[0] = { .node = 2, .desc = {
            .levels = alloc::new_array(allocator, LodLevel, 2), .parts = alloc::new_array(allocator, LodPart, 2),
        } };
        LodDesc* lod = &template.lod_groups[0].desc;
        lod.levels[0] = { .first_part = 0, .part_count = 1, .min_screen_size = 0.5 };
        lod.levels[1] = { .first_part = 1, .part_count = 1, .min_screen_size = 0 };
        foreach (&part : lod.parts) *part = { .geometry = lod_geometry, .material = material, .local = matrix::IDENTITY4 };
        return document;
    };
}

<*
 Generate deterministic bytes without encoded or binary fixture files.
 @require bytes <= (usz)sz::max
*>
fn char[] preparation_texture_bytes(Allocator allocator, usz bytes, uint seed = PREPARATION_IMAGE_SEED) {
    char[] pixels = alloc::new_array(allocator, char, (sz)bytes);
    uint state = seed;
    foreach (&byte : pixels) {
        state = state * PREPARATION_RANDOM_MULTIPLIER + PREPARATION_RANDOM_INCREMENT;
        *byte = (char)(state >> 24);
    }
    return pixels;
}
