module c3d::serial::test_described;

import c3d;
import c3d::asset::gltf;
import c3d::ecs;
import c3d::model;
import c3d::scene;
import c3d::serial @public;
import std::io::path;

fn String skin_fixture_path() @private {
    Path source = path::tnew($$FILEPATH)!!;
    return (String)source.parent()!!.tappend("../../../test/fixtures/gltf", "skin.gltf")!!;
}

fn String replace_token(String text, TextValue token, String replacement) @private {
    char[] result = alloc::new_array(tmem, char, text.len - token.length + replacement.len);
    result[:token.offset] = ((char[])text[:token.offset])[..];
    result[token.offset:replacement.len] = ((char[])replacement)[..];
    result[token.offset + replacement.len..] = ((char[])text[token.offset + token.length..])[..];
    return (String)result;
}

fn void test_skin_references_resolve_model_slots_in_both_encodings() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        String text = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            ModelInstance* instance = fixture.destination.get(restored, ModelInstance);
            SkinBinding* skin = fixture.destination.get(instance.present_node(1), SkinBinding);
            assert(skin.joints.len == 2);
            assert(skin.joints[0] == instance.present_node(2) && skin.joints[1] == instance.present_node(3));
            assert(instance.base_morph_weights.len == 1 && instance.base_morph_weights[0][0] == 0.5f);
            assert(bytes == serial::write_subtree(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!);
            fixture.destination.remove(restored);
        }
    };
}

fn void test_deleted_skin_joint_rejects_reused_pointer_and_absent_document_slot() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
        String text = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        TextDocument document = serial::parse_text(
            allocator: tmem,
            source: text,
            limits: serial::TEXT_LIMITS_DEFAULT,
            diagnostic: &diagnostic,
        )!!;
        defer serial::destroy_text_document(&document);
        uint nodes = serial::json_member(&document, 0, "nodes");
        uint components = serial::json_member(&document, nodes + 1, "components");
        uint model = serial::json_member(&document, components, "c3d.ModelInstance");
        uint value = serial::json_member(&document, model, "value");
        uint mapping = serial::json_member(&document, value, "nodes");
        uint absent = serial::json_member(&document, value, "absent");
        String edited = replace_token(text, document.values[absent], "[2]");
        edited = replace_token(edited, document.values[mapping + 3], "null");
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.diagnostic = &diagnostic;
        uint before = fixture.destination.world.entities.free_count;
        if (catch excuse = serial::read_subtree_text(
            scene: &fixture.destination,
            assets: &fixture.assets,
            text: edited,
            options: options,
        )) {
            assert(excuse == c3d::INVALID_ID);
        } else {
            assert(false);
        }
        assert(diagnostic.type_name == "c3d.SkinBinding" && diagnostic.model_key == skin_fixture_path());
        assert(diagnostic.has_template_index && diagnostic.template_index == 2 && diagnostic.has_text_position);
        assert(fixture.destination.world.entities.free_count == before && fixture.destination.root.first_child == null);
        ModelInstance* instance = fixture.source.get(source, ModelInstance);
        Node* removed = instance.present_node(2);
        fixture.source.remove(removed);
        Node* replacement = fixture.source.add_node(source, "replacement")!!;
        assert(replacement == removed && instance.present_node(2) == null);
        WriteOptions binary_options = { .diagnostic = &diagnostic };
        if (catch excuse = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
            options: binary_options,
        )) {
            assert(excuse == c3d::INVALID_ID);
        } else {
            assert(false);
        }
        assert(diagnostic.type_name == "c3d.SkinBinding" && diagnostic.template_index == 2);
        TextWriteOptions text_options = serial::TEXT_WRITE_OPTIONS_DEFAULT;
        text_options.diagnostic = &diagnostic;
        if (catch excuse = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
            options: text_options,
        )) {
            assert(excuse == c3d::INVALID_ID);
        } else {
            assert(false);
        }
        assert(diagnostic.type_name == "c3d.SkinBinding" && diagnostic.template_index == 2);
    };
}

fn void test_missing_model_clip_key_reports_asset_and_node_before_attachment() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        String text = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        ClipId clip = fixture.source.get(source, ModelInstance).clips[0];
        String key = fixture.assets.clip(clip).header.key.tcopy();
        fixture.assets.remove_clip(clip);
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.diagnostic = &diagnostic;
        uint before = fixture.destination.world.entities.free_count;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node*? restored = encoding == 0
              ? serial::read_subtree(
                  scene: &fixture.destination,
                  assets: &fixture.assets,
                  bytes: bytes,
                  options: options,
              )
              : serial::read_subtree_text(
                  scene: &fixture.destination,
                  assets: &fixture.assets,
                  text: text,
                  options: options,
              );
            if (catch excuse = restored) {
                assert(excuse == c3d::INVALID_ID);
            } else {
                assert(false);
            }
            assert(diagnostic.asset_key == key && diagnostic.node_path == "/nodes/0");
            assert(diagnostic.type_name == "c3d.ModelInstance");
            assert(fixture.destination.root.first_child == null && fixture.destination.world.entities.free_count == before);
        }
    };
}

fn void test_model_signature_detects_morph_and_skeleton_size_changes_under_same_keys() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
        ModelInstance* instance = fixture.source.get(source, ModelInstance);
        GeometryId geometry = fixture.source.get(instance.present_node(1), Mesh).geometry;
        SkeletonId skeleton = fixture.source.get(instance.present_node(1), SkinBinding).skeleton;
        char[] bytes = serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        String text = serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )!!;
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.diagnostic = &diagnostic;
        for (uint changed = 0; changed < 2; changed++) {
            uint targets = fixture.assets.geometry(geometry).target_count;
            int[] parents = fixture.assets.skeleton(skeleton).data.parents;
            if (changed == 0) {
                fixture.assets.geometry(geometry).target_count++;
            } else {
                fixture.assets.skeleton(skeleton).data.parents = parents[:1];
            }
            defer {
                fixture.assets.geometry(geometry).target_count = targets;
                fixture.assets.skeleton(skeleton).data.parents = parents;
            }
            for (uint encoding = 0; encoding < 2; encoding++) {
                Node*? restored = encoding == 0
                  ? serial::read_subtree(
                      scene: &fixture.destination,
                      assets: &fixture.assets,
                      bytes: bytes,
                      options: options,
                  )
                  : serial::read_subtree_text(
                      scene: &fixture.destination,
                      assets: &fixture.assets,
                      text: text,
                      options: options,
                  );
                if (catch excuse = restored) {
                    assert(excuse == serial::INCOMPATIBLE_TEMPLATE);
                } else {
                    assert(false);
                }
                assert(diagnostic.model_key == skin_fixture_path() && diagnostic.has_template_index);
                assert(diagnostic.template_index == 1 && diagnostic.type_name == "c3d.ModelInstance");
                assert(fixture.destination.root.first_child == null && fixture.destination.count(ModelInstance) == 0);
            }
        }
    };
}

fn void test_skin_joint_count_matches_reader_domain_and_copy_failure_attaches_nothing() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
        ModelInstance* instance = fixture.source.get(source, ModelInstance);
        SkinBinding* skin = fixture.source.get(instance.present_node(1), SkinBinding);
        Node*[] original_joints = skin.joints;
        skin.joints = original_joints[:1];
        defer skin.joints = original_joints;
        assert(@catch(serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )) == c3d::INVALID_ARGUMENT);
        assert(@catch(serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: source,
        )) == c3d::INVALID_ARGUMENT);
        Node* destination = fixture.destination.add_node(name: "skin")!!;
        Node* first = fixture.destination.add_node(destination, "first")!!;
        Node* second = fixture.destination.add_node(first, "second")!!;
        NodeReference[2] references = {
            { .node = first.id, .template_index = serial::INDEX_NONE },
            { .node = second.id, .template_index = serial::INDEX_NONE },
        };
        SkinAuthoring authoring = { .skeleton = skin.skeleton, .joints = references[..] };
        FailingAllocator allocator = { .failure = 1 };
        fixture.destination.allocator = &allocator;
        defer fixture.destination.allocator = mem;
        ReadContext context = { .scene = &fixture.destination, .assets = &fixture.assets, .node = destination };
        uint slot = ecs::assigned_slot(SkinBinding)!!;
        assert(@catch(serial::codecs[slot].described.codec.attach(&authoring, &context)) == c3d::CAPACITY_EXCEEDED);
        assert(allocator.attempts == 1 && allocator.outstanding == 0);
        assert(!fixture.destination.has(destination, SkinBinding));
        assert(fixture.destination.root.first_child == destination && first.parent == destination && second.parent == first);
        assert(original_joints[0] == instance.present_node(2) && original_joints[1] == instance.present_node(3));
    };
}
fn void test_model_signature_checks_earlier_duplicate_mesh_and_skin_slots() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = gltf::load_model(&fixture.assets, skin_fixture_path())!!;
        Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
        ModelInstance* instance = fixture.source.get(source, ModelInstance);
        ModelTemplate* template = &fixture.assets.model(model_id).data;
        ModelMesh mesh = template.meshes[0];
        alloc::free(mem, template.meshes.ptr);
        template.meshes = alloc::new_array(mem, ModelMesh, 2);
        template.meshes[..] = mesh;
        template.meshes[1].default_morph_weights = alloc::clone_slice(mem, mesh.default_morph_weights);
        ModelSkin skin = template.skins[0];
        alloc::free(mem, template.skins.ptr);
        template.skins = alloc::new_array(mem, ModelSkin, 2);
        template.skins[..] = skin;
        template.skins[1].joint_nodes = alloc::clone_slice(mem, skin.joint_nodes);
        alloc::free(mem, instance.mesh_nodes.ptr);
        instance.mesh_nodes = alloc::new_array(mem, uint, 2);
        instance.mesh_nodes[..] = mesh.node;
        float[] first_weights = instance.base_morph_weights[0];
        alloc::free(mem, instance.base_morph_weights.ptr);
        instance.base_morph_weights = alloc::new_array(mem, float[], 2);
        instance.base_morph_weights[0] = first_weights;
        instance.base_morph_weights[1] = alloc::clone_slice(mem, first_weights);
        MaterialId changed_material = fixture.assets.add_material({}, "earlier-slot")!!;
        char[] bytes = serial::write_subtree(
            allocator: tmem, scene: &fixture.source, assets: &fixture.assets, root: source,
        )!!;
        String text = serial::write_subtree_text(
            allocator: tmem, scene: &fixture.source, assets: &fixture.assets, root: source,
        )!!;
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.diagnostic = &diagnostic;
        for (uint changed = 0; changed < 2; changed++) {
            template.meshes[0].material = changed == 0 ? changed_material : mesh.material;
            template.skins[0].joint_nodes[0] = changed == 0 ? 2 : 3;
            assert(c3d::same_id(template.meshes[1].material, mesh.material));
            assert(template.skins[1].joint_nodes[0] == 2);
            for (uint encoding = 0; encoding < 2; encoding++) {
                Node*? result = encoding == 0
                  ? serial::read_subtree(
                      scene: &fixture.destination, assets: &fixture.assets, bytes: bytes, options: options,
                  )
                  : serial::read_subtree_text(
                      scene: &fixture.destination, assets: &fixture.assets, text: text, options: options,
                  );
                assert(@catch(result) == serial::INCOMPATIBLE_TEMPLATE);
                assert(diagnostic.model_key == skin_fixture_path() && diagnostic.template_index == 1);
                assert(diagnostic.type_name == "c3d.ModelInstance" && fixture.destination.root.first_child == null);
            }
        }
        template.skins[0].joint_nodes[0] = 2;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node* restored = encoding == 0
              ? serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!
              : serial::read_subtree_text(&fixture.destination, &fixture.assets, text)!!;
            ModelInstance* loaded = fixture.destination.get(restored, ModelInstance);
            assert(loaded.mesh_nodes.len == 2 && loaded.base_morph_weights.len == 2);
            assert(loaded.base_morph_weights[0][0] == mesh.default_morph_weights[0]);
            fixture.destination.remove(restored);
        }
    };
}