module c3d::serial::test_described;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::ecs;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::serial @public;
import std::math;

struct ModelRestoreAllocator (Allocator) @private {
    Scene* scene;
    sz failure_size;
    uint outstanding;
    bool failed;
    bool prior_camera;
}

fn void*? ModelRestoreAllocator.acquire(&self, sz size, AllocInitType init_type, sz alignment) @dynamic {
    if (!self.failed && size == self.failure_size && self.scene.count(Camera) > 0) {
        self.failed = true;
        self.prior_camera = true;
        return mem::OUT_OF_MEMORY~;
    }
    void* result = mem.acquire(size, init_type, alignment)!;
    self.outstanding++;
    return result;
}

fn void*? ModelRestoreAllocator.resize(&self, void* pointer, sz size, sz alignment) @dynamic {
    return mem.resize(pointer, size, alignment);
}

fn void ModelRestoreAllocator.release(&self, void* pointer, bool aligned) @dynamic {
    self.outstanding--;
    mem.release(pointer, aligned);
}

fn ModelId graph_model(Fixture* fixture) @private {
    ModelTemplate template;
    template.nodes = alloc::new_array(mem, NodeTemplate, 6);
    int[6] parents = { -1, 0, 0, 2, 3, 0 };
    String[6] names = { "parent", "leaf", "branch", "child", "grandchild", "kept" };
    foreach (index, &node : template.nodes) {
        *node = {
            .parent = parents[index],
            .name = names[index].copy(mem),
            .local = maths::TRANSFORM_IDENTITY,
            .layers = 1,
            .visible = true,
        };
    }
    template.cameras = alloc::new_array(mem, ModelCamera, 1);
    template.cameras[0] = { .node = 5, .value = camera::perspective_deg(60, 0.1f) };
    return fixture.assets.add_model_owned(&template, "graph")!!;
}

fn void test_model_mapping_retains_absence_reused_slots_and_authored_graph_in_both_encodings() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = graph_model(&fixture);
        Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
        ModelInstance* original = fixture.source.get(source, ModelInstance);
        Node* removed = original.present_node(1);
        fixture.source.remove(removed);
        Node* replacement = fixture.source.add_node(source, "replacement")!!;
        assert(replacement == removed && original.present_node(1) == null);
        fixture.source.add_node(original.present_node(3), "removed_application_child")!!;
        fixture.source.remove(original.present_node(2));
        fixture.source.remove_component(original.present_node(5), Camera);
        original.present_node(5).local.position = { 4, 5, 6 };
        original.base_pose[5].position = { 1, 2, 3 };
        fixture.source.add_node(original.present_node(5), "application_child")!!;
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
            ModelInstance* loaded = fixture.destination.get(restored, ModelInstance);
            assert(loaded.nodes.len == 6 && loaded.node_entities.len == 6 && loaded.base_pose.len == 6);
            assert(c3d::same_id(loaded.source, original.source));
            for (usz index = 0; index < 6; index++) {
                Node* before = original.present_node(index);
                Node* after = loaded.present_node(index);
                assert((before == null) == (after == null));
                assert(loaded.base_pose[index].position == original.base_pose[index].position);
                assert(loaded.base_pose[index].rotation.v == original.base_pose[index].rotation.v);
                assert(loaded.base_pose[index].scale == original.base_pose[index].scale);
                if (after) {
                    assert(c3d::same_id(loaded.node_entities[index], after.id));
                    assert(after.name == before.name && after.local.position == before.local.position);
                }
            }
            assert(!fixture.destination.has(loaded.present_node(5), Camera));
            assert(child_named(restored, "replacement").parent == restored);
            assert(child_named(loaded.present_node(5), "application_child").parent == loaded.present_node(5));
            assert(loaded.mesh_nodes.len == original.mesh_nodes.len && loaded.clips.len == original.clips.len);
            assert(loaded.base_morph_weights.len == original.base_morph_weights.len);
            assert(bytes == serial::write_subtree(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!);
            assert(text == serial::write_subtree_text(
                allocator: tmem,
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
            )!!);
            fixture.destination.remove(restored);
        }
    };
}

fn void test_model_signature_mismatch_reports_first_index_and_rolls_back_both_encodings() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = graph_model(&fixture);
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
        fixture.assets.model(model_id).data.nodes[5].parent = -1;
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.diagnostic = &diagnostic;
        uint free_before = fixture.destination.world.entities.free_count;
        for (uint encoding = 0; encoding < 2; encoding++) {
            Node*? result = encoding == 0
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
            if (catch excuse = result) {
                assert(excuse == serial::INCOMPATIBLE_TEMPLATE);
            } else {
                assert(false);
            }
            assert(diagnostic.model_key == "graph" && diagnostic.has_template_index && diagnostic.template_index == 5);
            assert(diagnostic.node_path == "/nodes/0" && diagnostic.type_name == "c3d.ModelInstance");
            if (encoding) assert(diagnostic.has_text_position && diagnostic.pointer == "/nodes/0/components/c3d.ModelInstance/value");
            assert(fixture.destination.world.entities.free_count == free_before);
            assert(fixture.destination.root.first_child == null && fixture.destination.count(ModelInstance) == 0);
        }
    };
}

fn void test_model_owned_array_failure_rolls_back_after_prior_component_attachment() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = graph_model(&fixture);
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
        Node* existing = fixture.destination.add_node(name: "existing")!!;
        existing.local.position = { 17, 19, 23 };
        existing.layers = 42;
        existing.visible = false;
        Entity identity = existing.id;
        uint free_before = fixture.destination.world.entities.free_count;
        uint models_before = fixture.assets.models.free_count;
        uint revision = fixture.assets.model(model_id).header.revision;
        ReadOptions options = serial::READ_OPTIONS_DEFAULT;
        options.allocator = mem;
        for (uint encoding = 0; encoding < 2; encoding++) {
            ModelRestoreAllocator allocator = {
                .scene = &fixture.destination, .failure_size = 6 * Node*::size,
            };
            fixture.destination.allocator = &allocator;
            *fixture.destination.hook_allocator = &allocator;
            defer {
                fixture.destination.allocator = mem;
                *fixture.destination.hook_allocator = mem;
            }
            Node*? result = encoding == 0
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
            if (catch excuse = result) {
                assert(excuse == c3d::CAPACITY_EXCEEDED);
            } else {
                assert(false);
            }
            assert(allocator.failed && allocator.prior_camera && allocator.outstanding == 0);
            assert(fixture.destination.count(Camera) == 0 && fixture.destination.count(ModelInstance) == 0);
            assert(fixture.destination.root.first_child == existing && existing.next_sibling == null);
            assert(c3d::same_id(existing.id, identity) && existing.name == "existing");
            assert(existing.local.position == (Vec3){ 17, 19, 23 } && existing.layers == 42 && !existing.visible);
            assert(fixture.destination.world.entities.free_count == free_before);
            assert(fixture.assets.models.free_count == models_before && fixture.assets.model(model_id).header.revision == revision);
        }
    };
}

fn void test_model_mapping_rejects_duplicate_claims_before_attachment_and_partial_exports() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        ModelId model_id = graph_model(&fixture);
        Node* source = model::instantiate(&fixture.assets, &fixture.source, model_id)!!;
        ModelInstance* instance = fixture.source.get(source, ModelInstance);
        Node* branch = instance.present_node(2);
        assert(@catch(serial::write_subtree(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: branch,
        )) == c3d::INVALID_ARGUMENT);
        assert(@catch(serial::write_subtree_text(
            allocator: tmem,
            scene: &fixture.source,
            assets: &fixture.assets,
            root: branch,
        )) == c3d::INVALID_ARGUMENT);
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
        uint nodes = member(&document, 0, "nodes");
        uint components = member(&document, nodes + 1, "components");
        uint model = member(&document, components, "c3d.ModelInstance");
        uint value = member(&document, model, "value");
        uint mapping = member(&document, value, "nodes");
        TextValue first = document.values[mapping + 1];
        TextValue second = document.values[mapping + 2];
        String duplicate = text[first.offset:first.length];
        char[] edited = alloc::new_array(tmem, char, text.len - second.length + duplicate.len);
        edited[:second.offset] = ((char[])text[:second.offset])[..];
        edited[second.offset:duplicate.len] = ((char[])duplicate)[..];
        edited[second.offset + duplicate.len..] = ((char[])text[second.offset + second.length..])[..];
        uint before = fixture.destination.world.entities.free_count;
        assert(@catch(serial::read_subtree_text(&fixture.destination, &fixture.assets, (String)edited))
          == c3d::ASSET_FORMAT_ERROR);
        assert(fixture.destination.world.entities.free_count == before);
        assert(fixture.destination.root.first_child == null);
        assert(fixture.destination.count(ModelInstance) == 0 && fixture.destination.count(Camera) == 0);
        assert(instance.present_node(2) == branch && fixture.source.has(instance.present_node(5), Camera));
    };
}