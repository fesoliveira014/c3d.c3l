module c3d::test::lod_v1_freeze;

import std::math;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::serial @public;
import std::hash::sha256;
import std::io;
import std::io::file;
import std::io::path;

const String HEX_DIGITS @local = "0123456789abcdef";

fn String output_path(String directory, String filename) @local {
    Path root = path::tnew(directory)!!;
    return (String)root.tappend(filename)!!;
}

fn char[64] digest_hex(char[32] digest) @local {
    char[64] hex;
    foreach (index, byte : digest) {
        hex[index * 2] = HEX_DIGITS[byte >> 4];
        hex[index * 2 + 1] = HEX_DIGITS[byte & 15];
    }
    return hex;
}

fn void? save_owner(
    Scene* scene,
    AssetStore* assets,
    Node* owner,
    String directory,
    String binary_name,
    String text_name,
) @local {
    char[] bytes = serial::write_subtree(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: owner,
    )!;
    String text = serial::write_subtree_text(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: owner,
    )!;
    file::save(output_path(directory, binary_name), bytes)!;
    file::save(output_path(directory, text_name), (char[])text)!;
    char[64] binary_hash = digest_hex(sha256::hash(bytes));
    char[64] text_hash = digest_hex(sha256::hash((char[])text));
    io::printfn("%s  %s (%s bytes)", (String)binary_hash[..], binary_name, bytes.len);
    io::printfn("%s  %s (%s bytes)", (String)text_hash[..], text_name, text.len);
}

fn void? freeze_lod_v1(String directory) @local {
    AssetStore assets = asset::create_asset_store(mem, {
        .max_geometries = 2,
        .max_textures = 8,
        .max_materials = 2,
        .max_samplers = 8,
        .max_models = 1,
        .max_skeletons = 1,
        .max_clips = 1,
        .max_environments = 1,
        .max_shaders = 1,
        .max_compute_shaders = 1,
        .max_fonts = 1,
    });
    defer asset::destroy_asset_store(&assets);

    Scene scene = scene::create_scene(mem, { .max_nodes = 8 });
    defer scene::destroy_scene(&scene);

    serial::register_core_codecs()!;
    if (serial::codecs[ecs::assigned_slot(LodGroup)!].codec.version != 1) return c3d::ASSET_FORMAT_ERROR~;

    Geometry box = geometry::box(
        allocator: tmem,
        width: 1,
        height: 1,
        depth: 1,
    );
    GeometryId geometry_id = assets.add_geometry(&box, "lod_v1/box")!;
    MaterialId material_id = assets.add_material(material::basic({}), "lod_v1/material")!;
    char[8 * 16 * 4] pixels;
    pixels[..] = 255;
    TextureId atlas = assets.add_texture({
        .width = 8, .height = 16, .format = RGBA8_UNORM, .layers = 1, .mip_levels = 1,
    }, pixels[..], "lod_v1/atlas")!;

    Mat4 affine = matrix::IDENTITY4;
    affine.m01 = 0.125f;
    affine.m03 = 2;
    LodPart[2] parts = {
        { .geometry = geometry_id, .material = material_id, .local = affine },
        { .geometry = geometry_id, .material = material_id, .local = matrix::IDENTITY4 },
    };
    LodLevel[2] levels = {
        { .part_count = 1, .min_screen_size = 0.2f },
        { .first_part = 1, .part_count = 1 },
    };
    LodDesc desc = { .parts = parts[..], .levels = levels[..] };
    Transform[1] placements = { maths::TRANSFORM_IDENTITY };
    placements[0].position = { 1, 2, 3 };
    Vec4[1] colors = { { 0.1f, 0.2f, 0.3f, 1 } };

    Node* instanced = scene.add_instanced_lod_group(
        assets: &assets,
        desc: desc,
        capacity: 5,
        transforms: placements[..],
        colors: colors[..],
        name: "legacy_instanced",
    )!;
    instanced.local.position = { 4, 2, -8 };
    instanced.layers = 9;
    scene.set_lod_effects(instanced, {
        .cast_shadow = false, .receive_shadow = true, .trace = true,
    });

    Node* impostor = scene.add_lod_group(
        assets: &assets,
        desc: desc,
        name: "legacy_impostor",
    )!;
    impostor.local.position = { -4, 1, 6 };
    scene.set_lod_effects(impostor, {
        .cast_shadow = true, .receive_shadow = false, .trace = false,
    });
    scene.set_lod_impostor(
        assets: &assets,
        node: impostor,
        impostor: { .atlas = atlas, .bounds = { .radius = 4 }, .frames_per_side = 2, .cell_size = 4 },
        min_screen_size: 0.1f,
    )!;

    save_owner(
        scene: &scene,
        assets: &assets,
        owner: instanced,
        directory: directory,
        binary_name: "lod-v1-instanced.bin",
        text_name: "lod-v1-instanced.jsonc",
    )!;
    save_owner(
        scene: &scene,
        assets: &assets,
        owner: impostor,
        directory: directory,
        binary_name: "lod-v1-impostor.bin",
        text_name: "lod-v1-impostor.jsonc",
    )!;
}

<* Emit compatibility inputs through the historical LodGroup v1 writer. *>
fn int main(String[] arguments) {
    if (arguments.len != 2) {
        io::eprintn("Usage: lod_v1_freeze OUTPUT_DIRECTORY");
        return 2;
    }

    @pool() {
        if (catch excuse = freeze_lod_v1(arguments[1])) {
            io::eprintfn("LodGroup v1 freeze failed: %s.", excuse);
            return 1;
        }
    };

    return 0;
}
