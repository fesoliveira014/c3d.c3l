module c3d::serial::test_described;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::model;
import c3d::scene;
import c3d::serial @public;
import std::math;

fn ModelId index_model(AssetStore* assets, String key) @local {
    ModelTemplate template;
    template.nodes = alloc::new_array(mem, NodeTemplate, 2);
    foreach (&node : template.nodes) {
        *node = {
            .parent = -1, .name = "node".copy(mem),
            .local = maths::TRANSFORM_IDENTITY, .layers = 1, .visible = true,
        };
    }
    return assets.add_model_owned(&template, key)!!;
}

fn void? collect_required_index_reference(void* component, WriteContext* context) @local {
    (void)context.make_entity_reference(((Number*)component).target, true)!;
}

fn void test_export_index_preserves_reused_generation_and_first_absent_skin_diagnostics() @test {
    @pool() {
        Fixture fixture;
        create_fixture(&fixture, max_nodes: 32, max_models: 3);
        defer destroy_fixture(&fixture);
        serial::register_core_codecs()!!;
        serial::register_described(Number, {
            .name = "number", .phase = REFERENCES, .collect = &collect_required_index_reference,
        })!!;
        defer register_described_codecs();
        Node* root = fixture.source.add_node(name: "root")!!;
        ModelId decoy_id = index_model(&fixture.assets, "index/decoy");
        ModelId first_id = index_model(&fixture.assets, "index/first");
        ModelId second_id = index_model(&fixture.assets, "index/second");
        Node* decoy = model::instantiate(
            assets: &fixture.assets,
            scene: &fixture.source,
            model: decoy_id,
            parent: root,
        )!!;
        Node* first = model::instantiate(
            assets: &fixture.assets,
            scene: &fixture.source,
            model: first_id,
            parent: root,
        )!!;
        Node* removed = fixture.source.get(first, ModelInstance).present_node(0);
        Entity first_dead = removed.id;
        Node* spare_root = fixture.source.add_node(root, "spare_root")!!;
        Node* spare_node = fixture.source.add_node(root, "spare_node")!!;
        fixture.source.remove(removed);
        fixture.source.remove(spare_node);
        fixture.source.remove(spare_root);
        Node* second = model::instantiate(
            assets: &fixture.assets,
            scene: &fixture.source,
            model: second_id,
            parent: root,
        )!!;
        Node* reused = fixture.source.get(second, ModelInstance).present_node(1);
        Entity second_dead = reused.id;
        assert(reused == removed && first_dead.generation != second_dead.generation);
        assert(first.id.index < second.id.index);
        fixture.source.remove(decoy);
        fixture.source.remove(reused);
        Node* replacement = fixture.source.add_node(root, "replacement")!!;
        assert(replacement == removed && replacement.id.generation != second_dead.generation);
        Node* first_owner;
        fixture.source.@each(ModelInstance; entity, instance) {
            if (!first_owner) first_owner = fixture.source.node(entity);
        };
        assert(first_owner == second);
        Number* number = fixture.source.add(root, (Number){});
        SerialDiagnostic diagnostic = serial::create_serial_diagnostic(mem);
        defer serial::destroy_serial_diagnostic(&diagnostic);
        Entity[2] targets = { first_dead, second_dead };
        String[2] keys = { "index/first", "index/second" };
        for (uint target = 0; target < targets.len; target++) {
            number.target = targets[target];
            for (uint encoding = 0; encoding < 2; encoding++) {
                if (!encoding) {
                    if (catch excuse = serial::write_subtree(
                        allocator: tmem,
                        scene: &fixture.source,
                        assets: &fixture.assets,
                        root: root,
                        options: { .diagnostic = &diagnostic },
                    )) {
                        assert(excuse == c3d::INVALID_ID);
                    } else {
                        assert(false);
                    }
                } else {
                    TextWriteOptions options = serial::TEXT_WRITE_OPTIONS_DEFAULT;
                    options.diagnostic = &diagnostic;
                    if (catch excuse = serial::write_subtree_text(
                        allocator: tmem,
                        scene: &fixture.source,
                        assets: &fixture.assets,
                        root: root,
                        options: options,
                    )) {
                        assert(excuse == c3d::INVALID_ID);
                    } else {
                        assert(false);
                    }
                }
                assert(diagnostic.model_key == keys[target] && diagnostic.template_index == target);
                assert(diagnostic.has_template_index && diagnostic.type_name == "number");
                assert(diagnostic.node_path == "/nodes/0");
            }
        }
        fixture.source.remove_component(root, Number);
        Skeleton skeleton;
        skeleton.parents = alloc::new_array(mem, int, 1);
        skeleton.parents[0] = -1;
        skeleton.rest_pose = alloc::new_array(mem, Transform, 1);
        skeleton.rest_pose[0] = maths::TRANSFORM_IDENTITY;
        skeleton.inverse_bind = alloc::new_array(mem, Mat4, 1);
        skeleton.inverse_bind[0] = matrix::IDENTITY4;
        SkeletonId skeleton_id = fixture.assets.add_skeleton_owned(&skeleton, "index/skeleton")!!;
        Node*[] joints = alloc::new_array(mem, Node*, 1);
        joints[0] = replacement;
        fixture.source.add(root, (SkinBinding){ .skeleton = skeleton_id, .joints = joints });
        for (uint encoding = 0; encoding < 2; encoding++) {
            if (!encoding) {
                if (catch excuse = serial::write_subtree(
                    allocator: tmem,
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: root,
                    options: { .diagnostic = &diagnostic },
                )) {
                    assert(excuse == c3d::INVALID_ID);
                } else {
                    assert(false);
                }
            } else {
                TextWriteOptions options = serial::TEXT_WRITE_OPTIONS_DEFAULT;
                options.diagnostic = &diagnostic;
                if (catch excuse = serial::write_subtree_text(
                    allocator: tmem,
                    scene: &fixture.source,
                    assets: &fixture.assets,
                    root: root,
                    options: options,
                )) {
                    assert(excuse == c3d::INVALID_ID);
                } else {
                    assert(false);
                }
            }
            assert(diagnostic.model_key == "index/first" && diagnostic.template_index == 0);
            assert(diagnostic.has_template_index && diagnostic.type_name == "c3d.SkinBinding");
            assert(diagnostic.node_path == "/nodes/0");
        }
    };
}
