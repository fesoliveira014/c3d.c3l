module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::asset::image;
import c3d::camera;
import c3d::geometry;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::test::transparency_fixtures;
import std::os::env;
import std::core::string;
import std::hash::sha256;
import std::io;
import std::io::file;
import std::math;

const char[*] LAYERED_CC0_BYTES @private = $embed("../../fixtures/transparency/GlassVaseFlowers.glb");
const String LAYERED_CC0_SHA256 @private = "430c9937664cfc74299205dcc388e4269bb688817f3d3866ef35aab71e93b852";
const String LAYERED_CC0_DECODED_SHA256 @private = "b6811fbd796566fdade3045767093537b8d451dc8b664daecd4ee2dfa9884aa7";
const String LAYERED_CC0_HEX @private = "0123456789abcdef";
const uint LAYERED_CC0_WIDTH @private = 512;
const uint LAYERED_CC0_HEIGHT @private = 288;
const uint LAYERED_CC0_CHECKER_EXTENT @private = 32;
const Vec3 LAYERED_CC0_EYE @private = { 0.06f, 0.105f, 0.45f };
const Vec3 LAYERED_CC0_TARGET @private = { 0.06f, 0.105f, 0 };

fn void layered_cc0_hash_uint(sha256::Sha256* hash, uint value) @private {
    char[4] bytes;
    foreach (index, &byte : bytes) *byte = (char)(value >> (8 * index));
    hash.update(bytes[..]);
}

fn void layered_cc0_hash_ulong(sha256::Sha256* hash, ulong value) @private {
    char[8] bytes;
    foreach (index, &byte : bytes) *byte = (char)(value >> (8 * index));
    hash.update(bytes[..]);
}

fn void layered_cc0_hash_float(sha256::Sha256* hash, float value) @private {
    layered_cc0_hash_uint(hash, bitcast(value, uint));
}

fn void layered_cc0_hash_bytes(sha256::Sha256* hash, char[] bytes) @private {
    layered_cc0_hash_ulong(hash, bytes.len);
    hash.update(bytes);
}

fn void layered_cc0_hash_vec2_rows(sha256::Sha256* hash, Vec2[] rows) @private {
    layered_cc0_hash_ulong(hash, rows.len);
    foreach (row : rows) foreach (value : row) layered_cc0_hash_float(hash, value);
}

fn void layered_cc0_hash_vec3_rows(sha256::Sha256* hash, Vec3[] rows) @private {
    layered_cc0_hash_ulong(hash, rows.len);
    foreach (row : rows) foreach (value : row) layered_cc0_hash_float(hash, value);
}

fn void layered_cc0_hash_vec4_rows(sha256::Sha256* hash, Vec4[] rows) @private {
    layered_cc0_hash_ulong(hash, rows.len);
    foreach (row : rows) foreach (value : row) layered_cc0_hash_float(hash, value);
}

fn void layered_cc0_hash_float_rows(sha256::Sha256* hash, float[] rows) @private {
    layered_cc0_hash_ulong(hash, rows.len);
    foreach (value : rows) layered_cc0_hash_float(hash, value);
}

fn void layered_cc0_hash_slot(sha256::Sha256* hash, TextureSlot slot) @private {
    layered_cc0_hash_uint(hash, (uint)slot.texture.kind);
    switch (slot.texture.kind) {
        case ASSET:
            layered_cc0_hash_uint(hash, slot.texture.asset.index);
            layered_cc0_hash_uint(hash, slot.texture.asset.generation);
        case RENDER_TARGET:
            layered_cc0_hash_uint(hash, slot.texture.target.index);
            layered_cc0_hash_uint(hash, slot.texture.target.generation);
    }
    layered_cc0_hash_uint(hash, slot.sampler.index);
    layered_cc0_hash_uint(hash, slot.sampler.generation);
    layered_cc0_hash_uint(hash, slot.uv_set);
    foreach (value : slot.transform.offset) layered_cc0_hash_float(hash, value);
    foreach (value : slot.transform.scale) layered_cc0_hash_float(hash, value);
    layered_cc0_hash_float(hash, slot.transform.rotation);
}

fn void layered_cc0_hash_standard(sha256::Sha256* hash, StandardParams params) @private {
    foreach (value : params.base_color) layered_cc0_hash_float(hash, value);
    layered_cc0_hash_float(hash, params.metallic);
    layered_cc0_hash_float(hash, params.roughness);
    foreach (value : params.emissive) layered_cc0_hash_float(hash, value);
    layered_cc0_hash_float(hash, params.emissive_strength);
    layered_cc0_hash_float(hash, params.normal_scale);
    layered_cc0_hash_float(hash, params.occlusion_strength);
    foreach (slot : (TextureSlot[5]){ params.base_color_map, params.metallic_roughness_map,
        params.normal_map, params.occlusion_map, params.emissive_map }) {
        layered_cc0_hash_slot(hash, slot);
    }
}

fn void layered_cc0_hash_material(sha256::Sha256* hash, Material material) @private {
    layered_cc0_hash_uint(hash, (uint)material.kind);
    layered_cc0_hash_uint(hash, (uint)material.common.alpha_mode);
    layered_cc0_hash_uint(hash, (uint)material.common.blend_mode);
    layered_cc0_hash_float(hash, material.common.alpha_cutoff);
    layered_cc0_hash_uint(hash, (uint)material.common.double_sided);
    layered_cc0_hash_uint(hash, (uint)material.common.depth_test);
    layered_cc0_hash_uint(hash, (uint)material.common.depth_write);
    layered_cc0_hash_uint(hash, (uint)material.common.wireframe);
    switch (material.kind) {
        case BASIC:
            foreach (value : material.basic.color) layered_cc0_hash_float(hash, value);
            layered_cc0_hash_slot(hash, material.basic.map);
        case STANDARD:
            layered_cc0_hash_standard(hash, material.standard);
        case PHYSICAL:
            PhysicalParams params = material.physical;
            layered_cc0_hash_standard(hash, params.standard);
            float[11] scalars = {
                params.clearcoat, params.clearcoat_roughness, params.clearcoat_normal_scale,
                params.sheen_roughness, params.ior, params.specular, params.anisotropy,
                params.anisotropy_rotation, params.transmission, params.thickness,
                params.attenuation_distance,
            };
            layered_cc0_hash_float_rows(hash, scalars[..]);
            foreach (color : (Vec3[3]){ params.sheen_color, params.specular_color, params.attenuation_color }) {
                foreach (value : color) layered_cc0_hash_float(hash, value);
            }
            foreach (slot : (TextureSlot[10]){ params.clearcoat_map, params.clearcoat_roughness_map,
                params.clearcoat_normal_map, params.sheen_color_map, params.sheen_roughness_map,
                params.specular_map, params.specular_color_map, params.anisotropy_map,
                params.transmission_map, params.thickness_map }) {
                layered_cc0_hash_slot(hash, slot);
            }
        case TOON:
            foreach (value : material.toon.color) layered_cc0_hash_float(hash, value);
            layered_cc0_hash_slot(hash, material.toon.map);
            layered_cc0_hash_uint(hash, material.toon.steps);
            layered_cc0_hash_uint(hash, material.toon.gradient_map.index);
            layered_cc0_hash_uint(hash, material.toon.gradient_map.generation);
            foreach (value : material.toon.rim_color) layered_cc0_hash_float(hash, value);
            layered_cc0_hash_float(hash, material.toon.rim_strength);
            layered_cc0_hash_float(hash, material.toon.rim_power);
        case CUSTOM:
            layered_cc0_hash_uint(hash, material.custom.shader.index);
            layered_cc0_hash_uint(hash, material.custom.shader.generation);
            layered_cc0_hash_bytes(hash, material.custom.param_block);
            foreach (slot : material.custom.slots) layered_cc0_hash_slot(hash, slot);
            foreach (reference : material.custom.references) {
                layered_cc0_hash_uint(hash, reference.index);
                layered_cc0_hash_uint(hash, reference.generation);
            }
    }
}

fn char[64] layered_cc0_decoded_hash(ModelDocument* document) @private {
    sha256::Sha256 hash;
    hash.init();
    layered_cc0_hash_bytes(&hash, (char[])"geometry_texture_nodes_materials_v1");
    layered_cc0_hash_ulong(&hash, document.geometries.len);
    foreach (entry : document.geometries) {
        Geometry geometry = entry.data;
        layered_cc0_hash_bytes(&hash, entry.key);
        layered_cc0_hash_uint(&hash, (uint)entry.tangent_provenance.origin);
        layered_cc0_hash_uint(&hash, entry.tangent_provenance.uv_set);
        layered_cc0_hash_uint(&hash, entry.tangent_provenance.derivation_revision);
        layered_cc0_hash_uint(&hash, (uint)geometry.topology);
        layered_cc0_hash_vec3_rows(&hash, geometry.positions);
        layered_cc0_hash_vec3_rows(&hash, geometry.normals);
        layered_cc0_hash_vec4_rows(&hash, geometry.tangents);
        layered_cc0_hash_vec2_rows(&hash, geometry.uv0);
        layered_cc0_hash_vec2_rows(&hash, geometry.uv1);
        layered_cc0_hash_vec4_rows(&hash, geometry.colors);
        layered_cc0_hash_ulong(&hash, geometry.joints.len);
        foreach (joint : geometry.joints) foreach (value : joint) layered_cc0_hash_uint(&hash, value);
        layered_cc0_hash_vec4_rows(&hash, geometry.weights);
        layered_cc0_hash_ulong(&hash, geometry.indices.len);
        foreach (index : geometry.indices) layered_cc0_hash_uint(&hash, index);
        layered_cc0_hash_ulong(&hash, geometry.targets.len);
        foreach (target : geometry.targets) {
            layered_cc0_hash_bytes(&hash, target.name);
            layered_cc0_hash_vec3_rows(&hash, target.position_deltas);
            layered_cc0_hash_vec3_rows(&hash, target.normal_deltas);
        }
        layered_cc0_hash_ulong(&hash, geometry.channels.len);
        foreach (channel : geometry.channels) {
            layered_cc0_hash_bytes(&hash, channel.name);
            layered_cc0_hash_uint(&hash, channel.first_target);
            layered_cc0_hash_float_rows(&hash, channel.full_weights);
        }
        layered_cc0_hash_bytes(&hash, geometry.custom_data);
        layered_cc0_hash_uint(&hash, geometry.custom_stride);
        foreach (value : geometry.bounds.min) layered_cc0_hash_float(&hash, value);
        foreach (value : geometry.bounds.max) layered_cc0_hash_float(&hash, value);
    }
    layered_cc0_hash_ulong(&hash, document.textures.len);
    foreach (texture : document.textures) {
        TextureDesc desc = texture.desc;
        layered_cc0_hash_bytes(&hash, texture.key);
        foreach (value : (uint[10]){ desc.width, desc.height, desc.depth, desc.layers,
            (uint)desc.format, (uint)desc.semantic, (uint)desc.coverage, desc.mip_levels,
            (uint)texture.source_kind, (uint)desc.generate_mips }) {
            layered_cc0_hash_uint(&hash, value);
        }
        layered_cc0_hash_uint(&hash, (uint)desc.is_cube);
        layered_cc0_hash_uint(&hash, (uint)desc.storage);
        layered_cc0_hash_ulong(&hash, bitcast(desc.alpha_threshold, ulong));
        layered_cc0_hash_bytes(&hash, texture.pixels);
        layered_cc0_hash_ulong(&hash, texture.supplied_mips.len);
        foreach (mip : texture.supplied_mips) {
            layered_cc0_hash_uint(&hash, mip.mip);
            layered_cc0_hash_uint(&hash, mip.layer);
            layered_cc0_hash_bytes(&hash, mip.bytes);
        }
    }
    layered_cc0_hash_ulong(&hash, document.samplers.len);
    foreach (sampler : document.samplers) {
        SamplerDesc desc = sampler.desc;
        layered_cc0_hash_bytes(&hash, sampler.key);
        foreach (value : (uint[9]){ (uint)desc.min_filter, (uint)desc.mag_filter, (uint)desc.mip_filter,
            (uint)desc.address_u, (uint)desc.address_v, (uint)desc.address_w,
            (uint)desc.anisotropy_enable, (uint)desc.compare_enable, (uint)desc.compare }) {
            layered_cc0_hash_uint(&hash, value);
        }
        layered_cc0_hash_float(&hash, desc.max_anisotropy);
    }
    layered_cc0_hash_ulong(&hash, document.materials.len);
    foreach (material : document.materials) {
        layered_cc0_hash_bytes(&hash, material.key);
        layered_cc0_hash_material(&hash, material.data);
    }
    layered_cc0_hash_ulong(&hash, document.template.nodes.len);
    foreach (node : document.template.nodes) {
        layered_cc0_hash_uint(&hash, bitcast(node.parent, uint));
        layered_cc0_hash_bytes(&hash, node.name);
        foreach (value : node.local.position) layered_cc0_hash_float(&hash, value);
        foreach (value : node.local.rotation.v) layered_cc0_hash_float(&hash, value);
        foreach (value : node.local.scale) layered_cc0_hash_float(&hash, value);
        layered_cc0_hash_uint(&hash, node.layers);
        layered_cc0_hash_uint(&hash, (uint)node.visible);
    }
    layered_cc0_hash_ulong(&hash, document.template.meshes.len);
    foreach (mesh : document.template.meshes) {
        layered_cc0_hash_uint(&hash, mesh.node);
        layered_cc0_hash_uint(&hash, mesh.geometry.index);
        layered_cc0_hash_uint(&hash, mesh.geometry.generation);
        layered_cc0_hash_uint(&hash, mesh.material.index);
        layered_cc0_hash_uint(&hash, mesh.material.generation);
        layered_cc0_hash_float_rows(&hash, mesh.default_morph_weights);
    }
    char[32] digest = hash.final();
    char[64] hexadecimal;
    foreach (index, value : digest) {
        hexadecimal[index * 2] = LAYERED_CC0_HEX[value >> 4];
        hexadecimal[index * 2 + 1] = LAYERED_CC0_HEX[value & 15];
    }
    return hexadecimal;
}

fn ModelId? load_layered_cc0_model(Fixture* fixture) @private {
    assert(LAYERED_CC0_BYTES.len == 1_819_824);
    char[32] digest = sha256::hash(LAYERED_CC0_BYTES[..]);
    char[64] hexadecimal;
    foreach (index, value : digest) {
        hexadecimal[index * 2] = LAYERED_CC0_HEX[value >> 4];
        hexadecimal[index * 2 + 1] = LAYERED_CC0_HEX[value & 15];
    }
    assert((String)hexadecimal[..] == LAYERED_CC0_SHA256);
    gltf::SourceRecord source;
    ModelDocument document = gltf::decode_model_memory_with_source(
        allocator: fixture.allocator,
        bytes: LAYERED_CC0_BYTES[..],
        base_dir: "",
        key: "glass_vase_flowers",
        source: &source,
    )!;
    defer asset::destroy_model_document(&document);
    defer gltf::destroy_source_record(&source);
    io::printfn("cc0 source_sha256=%s nodes=%s meshes=%s geometries=%s materials=%s textures=%s",
        LAYERED_CC0_SHA256, document.template.nodes.len, document.template.meshes.len,
        document.geometries.len, document.materials.len, document.textures.len);
    char[64] decoded_sha = layered_cc0_decoded_hash(&document);
    assert((String)decoded_sha[..] == LAYERED_CC0_DECODED_SHA256);
    io::printfn("cc0 decoded_schema=geometry_texture_nodes_materials_v1 decoded_sha256=%s",
        (String)decoded_sha[..]);
    foreach (name : source.extensions_required) {
        io::printfn("cc0 required_extension=%s", name);
    }
    uint glass_materials;
    foreach (index, material : source.materials) {
        bool transmission;
        bool volume;
        if (material.name == "GlassTransmission") {
            glass_materials++;
            assert(material.extensions.len == 2);
        } else {
            assert(material.extensions.len == 0);
        }
        foreach (name : material.extensions) {
            bool supported;
            foreach (known : gltf::SUPPORTED_MATERIAL_EXTENSIONS) supported |= name == known;
            assert(supported);
            transmission |= name == "KHR_materials_transmission";
            volume |= name == "KHR_materials_volume";
            io::printfn("cc0 source_material=%s name=%s extension=%s supported=%s",
                index, material.name, name, supported);
        }
        if (material.name == "GlassTransmission") assert(transmission && volume);
    }
    assert(glass_materials == 1);
    foreach (index, texture : source.textures) {
        assert(texture.extensions.len == 0);
        foreach (name : texture.extensions) {
            io::printfn("cc0 source_texture=%s extension=%s supported=false", index, name);
        }
    }
    return fixture.assets.publish_document(&document);
}

fn void? add_layered_cc0_checker(Fixture* fixture, Scene* target) @private {
    @pool() {
        sz checker_pixels = LAYERED_CC0_CHECKER_EXTENT * LAYERED_CC0_CHECKER_EXTENT;
        transparency_fixtures::ColorImage checker = {
            .width = LAYERED_CC0_CHECKER_EXTENT,
            .height = LAYERED_CC0_CHECKER_EXTENT,
            .pixels = alloc::new_array(tmem, transparency_fixtures::Color, checker_pixels),
        };
        transparency_fixtures::fill_backdrop(checker, transparency_fixtures::BackdropPattern.CHECKER);
        Vec4[] texels = alloc::new_array(tmem, Vec4, checker.pixels.len);
        foreach (index, color : checker.pixels) texels[index] = { (float)color.x, (float)color.y, (float)color.z, 1 };
        material::TextureDesc desc = {
            .width = checker.width,
            .height = checker.height,
            .layers = 1,
            .mip_levels = 1,
            .format = PixelFormat.RGBA32_FLOAT,
            .debug_name = "glass_checker",
        };
        TextureId texture = fixture.assets.add_texture(desc, ((char*)texels.ptr)[:texels.len * Vec4::size])!;
        Vec3[4] positions = {
            { -0.3f, -0.3f, -0.2f }, { 0.3f, -0.3f, -0.2f },
            { 0.3f, 0.3f, -0.2f }, { -0.3f, 0.3f, -0.2f },
        };
        Vec2[4] uv = { { 0, 1 }, { 1, 1 }, { 1, 0 }, { 0, 0 } };
        Geometry geometry = {
            .positions = positions[..],
            .uv0 = uv[..],
            .indices = transparency_fixtures::QUAD_INDICES[..],
        };
        geometry.finalize();
        GeometryId geometry_id = fixture.assets.add_geometry(&geometry)!;
        MaterialId material = fixture.assets.add_material(material::basic({
            .color = { 1, 1, 1, 1 },
            .map = material::texture_slot(texture, asset::SAMPLER_NEAREST),
        }))!;
        Node* checker_node = target.add_mesh(geometry_id, material)!;
        checker_node.local.position = { LAYERED_CC0_TARGET.x, LAYERED_CC0_TARGET.y, 0 };
    };
}

fn LayeredScene? create_layered_cc0_scene(Fixture* fixture, ModelId model) @private {
    LayeredScene result = { .scene = scene::create_scene(fixture.allocator, scene::default_scene_desc()) };
    defer catch scene::destroy_scene(&result.scene);
    Node* root = model::instantiate(&fixture.assets, &result.scene, model)!;
    assert(root.local.position == (Vec3){} && root.local.scale == (Vec3){ 1, 1, 1 });
    ModelTemplate* authored = &fixture.assets.model(model).data;
    ModelInstance* instance = result.scene.get(root, ModelInstance);
    foreach (usz index, node : authored.nodes) {
        Transform local = instance.present_node(index).local;
        assert(local.position == node.local.position && local.rotation.v == node.local.rotation.v
          && local.scale == node.local.scale);
    }
    foreach (mesh : authored.meshes) {
        Mesh* present = result.scene.get(instance.present_node(mesh.node), Mesh);
        assert(c3d::same_id(present.geometry, mesh.geometry) && c3d::same_id(present.material, mesh.material));
    }
    result.camera = result.scene.add_camera(camera::perspective_deg(30, 0.01f, 10))!;
    result.camera.local.position = LAYERED_CC0_EYE;
    result.camera.local.rotation = maths::look_rotation(LAYERED_CC0_TARGET - LAYERED_CC0_EYE, { 0, 1, 0 });
    Node* sun = result.scene.add_light(light::directional({ 1, 1, 1 }, 1, false))!;
    sun.local.rotation = maths::look_rotation((Vec3){ -1, -2, -3 }.normalize(), { 0, 1, 0 });
    add_layered_cc0_checker(fixture, &result.scene)!;
    result.scene.update_world();
    return result;
}

fn void? write_layered_cc0_capture(String name, Vec4[] pixels) @private {
    @pool() {
        String directory = env::tget_var("C3D_TRANSPARENCY_OUTPUT")!;
        file::save(string::tformat("%s/%s.rgba32f", directory, name),
            ((char*)pixels.ptr)[:pixels.len * Vec4::size])!;
        char[] rgba = alloc::new_array(tmem, char, (sz)(pixels.len * 4));
        foreach (pixel, color : pixels) {
            for (uint channel = 0; channel < 3; channel++) {
                assert(math::is_finite(color[channel]));
                rgba[4 * pixel + channel] = (char)math::round(math::clamp(color[channel], 0.0f, 1.0f) * 255);
            }
            rgba[4 * pixel + 3] = 255;
        }
        image::write_png(
            path: string::tformat("%s/%s.png", directory, name),
            width: LAYERED_CC0_WIDTH,
            height: LAYERED_CC0_HEIGHT,
            pixels: rgba,
        )!;
    };
}

fn uint[]? capture_layered_cc0_groups(
    Fixture* fixture,
    LayeredView* view,
    String name,
    uint capacity,
) @private {
    uint[] count = mem::new_array(uint, LAYERED_CC0_WIDTH * LAYERED_CC0_HEIGHT);
    defer catch free(count);
    uint[] overflow;
    for (uint group = 0; group <= capacity; group++) {
        uint[] depth = read_layered_depth(fixture, view, group)!;
        if (group == capacity) {
            overflow = depth;
        } else {
            foreach (pixel, bits : depth) if (bits) count[pixel]++;
            free(depth);
        }
    }
    defer free(overflow);
    @pool() {
        String directory = env::tget_var("C3D_TRANSPARENCY_OUTPUT")!;
        file::save(string::tformat("%s/%s.groups.u32", directory, name),
            ((char*)count.ptr)[:count.len * uint::size])!;
        String overflow_path = string::tformat("%s/%s.overflow_depth.u32", directory, name);
        char[] overflow_bytes = ((char*)overflow.ptr)[:overflow.len * uint::size];
        file::save(overflow_path, overflow_bytes)!;
    };
    foreach (pixel, bits : overflow) if (bits) count[pixel] = capacity + 1;
    return count;
}

fn void test_layered_cc0_authored_glass_identity_captures_both_paths_and_environment_fallbacks() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();
    Fixture fixture;
    create_fixture(&tracker, &fixture)!!;
    defer destroy_fixture(&fixture);
    ModelId model = load_layered_cc0_model(&fixture)!!;
    LayeredScene target = create_layered_cc0_scene(&fixture, model)!!;
    defer scene::destroy_scene(&target.scene);
    EnvironmentSettings settings = { .conversion_size = 32, .specular_size = 32 };
    EnvironmentId grey = fixture.assets.add_environment(light::solid_environment({ 0.25f, 0.25f, 0.25f }, settings))!!;
    EnvironmentId black = fixture.assets.add_environment(light::solid_environment({}, settings))!!;
    EnvironmentId[3] environments = { grey, (EnvironmentId){}, black };
    String[3] environment_names = { "constant", "missing", "black" };
    foreach (environment_index, environment : environments) {
        target.scene.environment = environment;
        foreach (shading : (ShadingPath[2]){ FORWARD, DEFERRED }) {
            LayeredView view = create_layered_view(&fixture, 4, shading)!!;
            defer destroy_layered_view(&fixture, &view);
            render::resize_render_target(
                renderer: &fixture.renderer,
                target: view.target,
                width: LAYERED_CC0_WIDTH,
                height: LAYERED_CC0_HEIGHT,
            )!!;
            Vec4[] capacity_four;
            uint[] four_groups;
            defer free(capacity_four.ptr);
            defer free(four_groups.ptr);
            foreach (capacity : (uint[3]){ 0, 4, 16 }) @pool() {
                ViewDesc desc = fixture.renderer.views.get(view.view).desc;
                desc.color = OutputMode.LINEAR_HDR;
                desc.transparency = capacity
                  ? (TransparencyDesc){ .mode = LAYERED, .layer_capacity = capacity } : (TransparencyDesc){};
                render::configure_view(&fixture.renderer, view.view, desc)!!;
                for (uint warm = 0; warm <= render::FRAMES_IN_FLIGHT; warm++) {
                    Vec4[] discarded = render_layered_pixels(&fixture, &target, &view)!!;
                    free(discarded);
                }
                Vec4[] linear = render_layered_pixels(&fixture, &target, &view)!!;
                defer free(linear);
                String name = string::tformat("glass_vase_%s_%s_k%s", environment_names[environment_index],
                    shading == FORWARD ? "forward" : "deferred", capacity);
                write_layered_cc0_capture(string::tformat("%s_linear", name), linear)!!;
                if (capacity) {
                    uint[] groups = capture_layered_cc0_groups(
                        fixture: &fixture,
                        view: &view,
                        name: name,
                        capacity: capacity,
                    )!!;
                    if (capacity == 4) {
                        capacity_four = mem::new_array(Vec4, linear.len);
                        capacity_four[..] = linear[..];
                        four_groups = groups;
                    } else {
                        defer free(groups);
                        foreach (pixel, count : four_groups) {
                            if (count > 4 || groups[pixel] > 16) continue;
                            transparency_fixtures::Color reference = {
                                (double)capacity_four[pixel].x,
                                (double)capacity_four[pixel].y,
                                (double)capacity_four[pixel].z,
                            };
                            check_layered_color(linear[pixel], reference);
                        }
                    }
                }
                desc.color = OutputMode.DISPLAY_LDR;
                render::configure_view(&fixture.renderer, view.view, desc)!!;
                Vec4[] presented = render_layered_pixels(&fixture, &target, &view)!!;
                defer free(presented);
                write_layered_cc0_capture(string::tformat("%s_presented", name), presented)!!;
                TransparencyStats stats = fixture.renderer.view_stats(view.view)!!.transparency;
                io::printfn("cc0 image=%s capture=%s retained=%s remainder=%s "
                    "resolve=%s filter=%s bytes=%s fallback=%s",
                    name, stats.capture_passes, stats.retained_passes, stats.remainder_passes,
                    stats.resolve_passes, stats.filter_passes, stats.payload_bytes, stats.fallback_draws);
            };
        }
    }
    check_validation(&fixture.renderer);
}
