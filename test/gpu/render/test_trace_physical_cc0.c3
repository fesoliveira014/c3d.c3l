module c3d::render::acceptance;

import c3d;
import c3d::asset;
import c3d::asset::gltf;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::render @public;
import c3d::scene;
import c3d::shader;
import std::hash::sha256;
import std::io;
import std::math;

const char[*] PHYSICAL_CC0_COAT_BYTES @private = $embed("../../fixtures/traced_parity/ClearCoatCarPaint.glb");
const char[*] PHYSICAL_CC0_SHEEN_BYTES @private = $embed("../../fixtures/traced_parity/SheenChair.glb");
const char[*] PHYSICAL_CC0_ANISOTROPY_BYTES @private = $embed("../../fixtures/traced_parity/AnisotropyDiscTest.glb");
const char[*] PHYSICAL_CC0_SOURCE @private = $embed("trace_physical_cc0.comp.glsl");
const String[3] PHYSICAL_CC0_NAMES @private = { "ClearCoatCarPaint", "SheenChair", "AnisotropyDiscTest" };
const String[3] PHYSICAL_CC0_EXTENSIONS @private = {
    "KHR_materials_clearcoat", "KHR_materials_sheen", "KHR_materials_anisotropy",
};
const String[3] PHYSICAL_CC0_HASHES @private = {
    "4d4b32f2ef6d341191f6b6d6834f2b192762c878cd25d44e6b4b14514cd4be93",
    "f0af2a2b102d28d540236306ae19f8fb36842df76bd38cf76f063f9bd2853399",
    "649b47c896f078fa56070f0ddaf07c57d6a7d109324acdd7d9f2d6748d9842ec",
};
const usz[3] PHYSICAL_CC0_LENGTHS @private = { 116948, 4125648, 242128 };
const float PHYSICAL_CC0_WITNESS_DISTANCE @private = 0.001f;
const float PHYSICAL_CC0_VIEW_TANGENT @private = 0.5f;
const double PHYSICAL_CC0_POSITION_ABSOLUTE @private = 2e-5;
const double PHYSICAL_CC0_POSITION_RELATIVE @private = 2e-4;

fn bool physical_cc0_has_lobe(Material* material, uint lobe) @private {
    if (material.kind != PHYSICAL) return false;
    switch (lobe) {
        case 0: return material.physical.clearcoat > 0;
        case 1: return material.physical.sheen_color != (Vec3){};
        case 2: return material.physical.anisotropy > 0;
    }
    return false;
}

fn void test_trace_physical_cc0_hashes_extensions_original_pose_and_full_hit_lobes() @test {
    char[][3] sources = {
        PHYSICAL_CC0_COAT_BYTES[..],
        PHYSICAL_CC0_SHEEN_BYTES[..],
        PHYSICAL_CC0_ANISOTROPY_BYTES[..],
    };
    foreach (hardware : (bool[2]){ false, true }) {
        Fixture fixture;
        create_fixture(mem, &fixture, ray_queries: hardware)!!;
        defer destroy_fixture(&fixture);
        String[1] defines = { hardware ? "SCENE_TRACE_RAY_QUERY" : "SCENE_TRACE_BVH" };
        ComputeShaderId shader_id = add_compute_shader(&fixture, (String)PHYSICAL_CC0_SOURCE[..], defines[..])!!;
        foreach (uint asset_index, bytes : sources) {
            assert(bytes.len == PHYSICAL_CC0_LENGTHS[asset_index]);
            char[32] digest = sha256::hash(bytes);
            char[64] hexadecimal;
            foreach (index, value : digest) {
                hexadecimal[index * 2] = LAYERED_CC0_HEX[value >> 4];
                hexadecimal[index * 2 + 1] = LAYERED_CC0_HEX[value & 15];
            }
            assert((String)hexadecimal[..] == PHYSICAL_CC0_HASHES[asset_index]);
            gltf::SourceRecord source;
            ModelDocument document = gltf::decode_model_memory_with_source(
                allocator: fixture.allocator,
                bytes: bytes,
                base_dir: "",
                key: PHYSICAL_CC0_NAMES[asset_index],
                source: &source,
            )!!;
            defer asset::destroy_model_document(&document);
            defer gltf::destroy_source_record(&source);
            uint extension_count;
            foreach (material : source.materials) {
                foreach (name : material.extensions) {
                    bool supported;
                    foreach (known : gltf::SUPPORTED_MATERIAL_EXTENSIONS) supported |= name == known;
                    assert(supported, "Unexpected unsupported CC0 material extension: %s", name);
                    extension_count += name == PHYSICAL_CC0_EXTENSIONS[asset_index] ? 1 : 0;
                }
            }
            assert(extension_count > 0);
            foreach (name : source.extensions_required) {
                assert(name == "KHR_texture_transform" || name == PHYSICAL_CC0_EXTENSIONS[asset_index]);
            }
            char[64] decoded_hash = layered_cc0_decoded_hash(&document);
            io::printfn("physical_cc0 source=%s source_hash=%s decoded_hash=%s",
                PHYSICAL_CC0_NAMES[asset_index], PHYSICAL_CC0_HASHES[asset_index], (String)decoded_hash[..]);
            ModelId model_id = fixture.assets.publish_document(&document)!!;
            Scene scene = scene::create_scene(mem, scene::default_scene_desc());
            defer scene::destroy_scene(&scene);
            scene.ambient_intensity = 0;
            scene.environment = reflection_solid(&fixture, { 0.25f, 0.5f, 1 })!!;
            Node* instance_root = model::instantiate(&fixture.assets, &scene, model_id)!!;
            assert(instance_root.local.position == (Vec3){} && instance_root.local.scale == (Vec3){ 1, 1, 1 });
            ModelTemplate* authored = &fixture.assets.model(model_id).data;
            ModelInstance* instance = scene.get(instance_root, ModelInstance);
            foreach (usz index, node : authored.nodes) {
                Transform local = instance.present_node(index).local;
                assert(local.position == node.local.position && local.rotation.v == node.local.rotation.v
                  && local.scale == node.local.scale);
            }
            foreach (mesh : authored.meshes) {
                Mesh* present = scene.get(instance.present_node(mesh.node), Mesh);
                assert(c3d::same_id(present.geometry, mesh.geometry) && c3d::same_id(present.material, mesh.material));
            }
            scene.update_world();
            Vec3 point;
            Vec3 normal;
            float distance;
            bool selected;
            foreach (mesh : authored.meshes) {
                Material* material = &fixture.assets.material(mesh.material).data;
                if (!physical_cc0_has_lobe(material, asset_index)) continue;
                Geometry* geometry = &fixture.assets.geometry(mesh.geometry).data;
                Mat4 world = instance.present_node(mesh.node).world;
                usz corners = geometry.indices.len ? geometry.indices.len : geometry.positions.len;
                for (usz triangle = 0; triangle < corners / 3; triangle++) {
                    usz first = triangle * 3;
                    Vec3[3] positions;
                    for (uint corner = 0; corner < 3; corner++) {
                        uint vertex = geometry.indices.len ? geometry.indices[first + corner] : (uint)(first + corner);
                        positions[corner] = maths::transform_point(world, geometry.positions[vertex]);
                    }
                    Vec3 edge_a = positions[1] - positions[0];
                    Vec3 edge_b = positions[2] - positions[0];
                    Vec3 face = edge_a.cross(edge_b);
                    if (face.dot(face) == 0) continue;
                    point = (positions[0] + positions[1] + positions[2]) / 3;
                    normal = face.normalize();
                    distance = math::min(edge_a.length(), edge_b.length()) * PHYSICAL_CC0_WITNESS_DISTANCE;
                    selected = true;
                    break;
                }
                if (selected) break;
            }
            assert(selected && distance > 0);
            Vec3 tangent = math::abs(normal.y) < 0.9f ? normal.cross((Vec3){ 0, 1, 0 }).normalize()
              : normal.cross((Vec3){ 1, 0, 0 }).normalize();
            Vec3 view = (normal + tangent * PHYSICAL_CC0_VIEW_TANGENT).normalize();
            Vec3 origin = point + view * distance;
            Vec3 direction = -view;
            LightGpu[1] lights = {
                { .direction_cos_outer = { -view.x, -view.y, -view.z, 0 },
                    .color_intensity = { 1, 1, 1, 1 }, .layers = uint::max },
            };
            io::printfn("physical_cc0 witness source=%s origin=%s direction=%s point=%s distance=%s",
                PHYSICAL_CC0_NAMES[asset_index], origin, direction, point, distance);
            Vec4[PHYSICAL_HIT_ROWS] actual = read_physical_hit(
                fixture: &fixture,
                scene: &scene,
                shader_id: shader_id,
                frame: {},
                origin: origin,
                direction: direction,
                lights: lights[..],
            )!!;
            assert(actual[0].w == (float)shader::MATERIAL_KIND_PHYSICAL);
            assert(actual[3][asset_index] > 0, "The immutable asset's selected lobe must be active at its hit");
            assert(actual[0].xyz != actual[1].xyz, "Full Physical hit must differ from its Standard approximation");
            for (uint channel = 0; channel < 3; channel++) {
                assert(math::is_finite(actual[0][channel]) && actual[0][channel] >= 0);
                double error = math::abs((double)actual[4][channel] - (double)point[channel]);
                double tolerance = PHYSICAL_CC0_POSITION_ABSOLUTE
                  + PHYSICAL_CC0_POSITION_RELATIVE * math::abs((double)point[channel]);
                assert(error <= tolerance, "The preselected CC0 triangle must be the actual hit");
            }
            check_validation(&fixture.renderer);
        }
    }
}
