module c3d::test::scene;

import c3d;
import c3d::camera;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import std::math;

const float TOLERANCE @local = 0.0005f;

struct Health @local {
    float value;
}

struct Tag @local {
    int label;
}

struct HookRecord @local {
    uint calls;
}

fn void record_removal(Entity entity, void* component, void* user) @local {
    ((HookRecord*)user).calls++;
}

fn bool close(float first, float second) @local {
    return math::abs(first - second) <= TOLERANCE;
}

fn bool close_vec3(Vec3 first, Vec3 second) @local {
    return close(first.x, second.x) && close(first.y, second.y) && close(first.z, second.z);
}

fn bool close_mat4(Mat4 first, Mat4 second) @local {
    for (usz index = 0; index < 16; index++) {
        if (!close(first.m[index], second.m[index])) return false;
    }
    return true;
}

fn Quat quarter_turn_y() @local {
    return quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::PI / 2);
}

fn Scene make_scene(uint max_nodes) @local {
    Scene scene = scene::create_scene(mem, { .max_nodes = max_nodes });
    scene.register(Health)!!;
    scene.register(Tag)!!;
    return scene;
}

fn void test_new_node_is_identity_under_its_parent() @test {
    Scene scene = make_scene(4);
    defer scene::destroy_scene(&scene);

    Node* node = scene.add_node()!!;

    assert(close_vec3(node.local.position, maths::TRANSFORM_IDENTITY.position));
    assert(close_vec3(node.local.scale, maths::TRANSFORM_IDENTITY.scale));
    assert(node.local.rotation.equals(quaternion::IDENTITY));
    assert(node.layers == scene::DEFAULT_LAYERS);
    assert(node.visible);
    assert(node.parent == scene.root);
    assert(scene.root.first_child == node);
    assert(scene.node(node.id) == node);

    scene.update_world();
    assert(close_mat4(node.world, matrix::IDENTITY4));
}

fn void test_child_world_composes_through_three_levels() @test {
    Scene scene = make_scene(4);
    defer scene::destroy_scene(&scene);

    Node* a = scene.add_node()!!;
    Node* b = scene.add_node(a)!!;
    Node* c = scene.add_node(b)!!;
    a.local.position = { 2, 0, 0 };
    b.local.position = { 0, 1, 0 };
    b.local.rotation = quarter_turn_y();
    c.local.position = { 1, 0, 0 };
    scene.update_world();

    assert(close_vec3(b.world_position(), { 2, 1, 0 }));
    assert(close_vec3(c.world_position(), { 2, 1, -1 }));
}

fn void test_second_update_without_edits_changes_nothing() @test {
    Scene scene = make_scene(4);
    defer scene::destroy_scene(&scene);

    Node* a = scene.add_node()!!;
    Node* b = scene.add_node(a)!!;
    a.local.position = { 1, 2, 3 };
    a.local.rotation = quarter_turn_y();
    b.local.scale = { 2, 2, 2 };
    scene.update_world();
    Mat4 first_a = a.world;
    Mat4 first_b = b.world;
    scene.update_world();

    assert(close_mat4(a.world, first_a));
    assert(close_mat4(b.world, first_b));
}

fn void test_hidden_parent_hides_descendants_after_update() @test {
    Scene scene = make_scene(4);
    defer scene::destroy_scene(&scene);

    Node* a = scene.add_node()!!;
    Node* b = scene.add_node(a)!!;
    Node* c = scene.add_node(b)!!;
    scene.update_world();
    assert(c.visible_effective);

    a.visible = false;
    assert(c.visible_effective);
    scene.update_world();
    assert(!b.visible_effective && !c.visible_effective);
    assert(b.visible && c.visible);

    a.visible = true;
    scene.update_world();
    assert(b.visible_effective && c.visible_effective);
}

fn void test_reparent_keeps_world_position() @test {
    Scene scene = make_scene(4);
    defer scene::destroy_scene(&scene);

    Node* a = scene.add_node()!!;
    Node* b = scene.add_node(a)!!;
    Node* c = scene.add_node()!!;
    a.local.position = { 1, 0, 0 };
    a.local.rotation = quarter_turn_y();
    a.local.scale = { 2, 2, 2 };
    b.local.position = { 0, 1, 2 };
    b.local.rotation = quaternion::from_euler{float}(0.3f, -0.5f, 0.8f);
    c.local.position = { -3, 1, 1 };
    c.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.7f);
    c.local.scale = { 0.5f, 0.5f, 0.5f };
    scene.update_world();
    Vec3 point = { 0.4f, -0.2f, 1.5f };
    Vec3 position_before = b.world_position();
    Vec3 point_before = maths::transform_point(b.world, point);

    scene.reparent(b, c, keep_world: true);
    scene.update_world();

    assert(b.parent == c);
    assert(close_vec3(b.world_position(), position_before));
    assert(close_vec3(maths::transform_point(b.world, point), point_before));
}

fn void test_reparent_without_keep_world_keeps_local() @test {
    Scene scene = make_scene(4);
    defer scene::destroy_scene(&scene);

    Node* a = scene.add_node()!!;
    Node* b = scene.add_node(a)!!;
    Node* c = scene.add_node()!!;
    a.local.position = { 1, 0, 0 };
    b.local.position = { 0, 1, 0 };
    c.local.position = { 0, 0, 5 };
    scene.update_world();

    scene.reparent(b, c);
    scene.update_world();

    assert(b.parent == c);
    assert(close_vec3(b.local.position, { 0, 1, 0 }));
    assert(close_vec3(b.world_position(), { 0, 1, 5 }));
}

fn void test_remove_destroys_subtree_and_runs_hooks() @test {
    Scene scene = make_scene(8);
    defer scene::destroy_scene(&scene);

    HookRecord record;
    scene.set_remove_hook(Tag, &record_removal, &record);
    Node* a = scene.add_node()!!;
    Node* b = scene.add_node(a)!!;
    Node* c = scene.add_node(a)!!;
    Node* d = scene.add_node()!!;
    scene.add(a, (Tag){ .label = 1 });
    scene.add(b, (Tag){ .label = 2 });
    scene.add(c, (Tag){ .label = 3 });
    scene.add(d, (Tag){ .label = 4 });
    Entity a_id = a.id;
    Entity b_id = b.id;
    Entity c_id = c.id;

    scene.remove(a);

    assert(!scene.world.is_alive(a_id) && !scene.world.is_alive(b_id) && !scene.world.is_alive(c_id));
    assert(record.calls == 3);
    assert(scene.world.is_alive(d.id));
    assert(scene.root.first_child == d && d.next_sibling == null);
    assert(scene.count(Tag) == 1);
}

fn void test_remove_later_during_each_flushes_afterwards() @test {
    Scene scene = make_scene(8);
    defer scene::destroy_scene(&scene);

    Entity[5] entities;
    for (uint index = 0; index < 5; index++) {
        Node* node = scene.add_node()!!;
        scene.add(node, (Health){ .value = index == 1 || index == 3 ? 0 : 10 });
        entities[index] = node.id;
    }

    scene.@each(Health; Entity entity, Health* health) {
        if (health.value <= 0) scene.remove_later(scene.node(entity));
    };
    assert(scene.world.is_alive(entities[1]) && scene.world.is_alive(entities[3]));
    assert(scene.count(Health) == 5);

    scene.flush_removals();
    assert(!scene.world.is_alive(entities[1]) && !scene.world.is_alive(entities[3]));
    assert(scene.count(Health) == 3);
    assert(scene.remove_count == 0);
}

fn void test_full_scene_faults_capacity() @test {
    Scene scene = make_scene(2);
    defer scene::destroy_scene(&scene);

    scene.add_node()!!;
    scene.add_node()!!;
    if (catch excuse = scene.add_node()) {
        assert(excuse == c3d::CAPACITY_EXCEEDED);
    } else {
        assert(false, "a full scene added a node");
    }
}

fn void test_find_returns_the_named_node_or_faults() @test {
    Scene scene = make_scene(4);
    defer scene::destroy_scene(&scene);

    Node* alpha = scene.add_node(name: "alpha")!!;
    Node* beta = scene.add_node(name: "beta")!!;

    assert(scene.find("beta")!! == beta);
    scene.remove(beta);
    if (catch excuse = scene.find("beta")) {
        assert(excuse == NOT_FOUND);
    } else {
        assert(false, "a removed node was found by name");
    }
    assert(scene.find("alpha")!! == alpha);
}

fn void test_node_address_survives_other_edits() @test {
    Scene scene = make_scene(8);
    defer scene::destroy_scene(&scene);

    Node* keep = scene.add_node(name: "keep")!!;
    Node* first = scene.add_node()!!;
    Entity second = scene.add_node(first)!!.id;
    scene.add_node()!!;
    scene.remove(first);
    scene.add_node(keep)!!;

    assert(scene.node(keep.id) == keep);
    assert(keep.name == "keep");
    assert(!scene.world.is_alive(second));
}

fn void test_layers_are_per_node() @test {
    Scene scene = make_scene(4);
    defer scene::destroy_scene(&scene);

    Node* a = scene.add_node()!!;
    Node* b = scene.add_node(a)!!;
    assert(a.layers == scene::DEFAULT_LAYERS && b.layers == scene::DEFAULT_LAYERS);

    a.layers = 4;
    scene.update_world();

    uint camera_mask = 4;
    assert(b.layers == scene::DEFAULT_LAYERS);
    assert((camera_mask & a.layers) != 0);
    assert((camera_mask & b.layers) == 0);
}

fn void test_look_at_faces_a_world_target_under_a_rotated_parent() @test {
    Scene scene = make_scene(4);
    defer scene::destroy_scene(&scene);

    Node* a = scene.add_node()!!;
    Node* b = scene.add_node(a)!!;
    a.local.position = { 1, 0, 0 };
    a.local.rotation = quarter_turn_y();
    b.local.position = { 0, 0, 2 };
    scene.update_world();

    Vec3 target = { 5, 0, 2 };
    b.look_at(target);
    scene.update_world();

    Vec3 forward = maths::transform_dir(b.world, { 0, 0, -1 }).normalize();
    Vec3 expected = (target - b.world_position()).normalize();
    assert(close_vec3(forward, expected));
}

fn void test_set_world_position_under_a_rotated_scaled_parent() @test {
    Scene scene = make_scene(4);
    defer scene::destroy_scene(&scene);

    Node* parent = scene.add_node()!!;
    Node* child = scene.add_node(parent)!!;
    parent.local.position = { 5, 0, 0 };
    parent.local.rotation = quarter_turn_y();
    parent.local.scale = { 2, 2, 2 };
    child.local.rotation = quarter_turn_y();
    child.local.scale = { 3, 3, 3 };
    scene.update_world();

    child.set_world_position({ 1, 2, 3 });
    scene.update_world();

    assert(close_vec3(child.world_position(), { 1, 2, 3 }));
    assert(math::abs(child.local.rotation.v.dot(quarter_turn_y().v)) > 1 - 1e-5);
    assert(close_vec3(child.local.scale, { 3, 3, 3 }));
}

fn void test_set_world_pose_under_a_rotated_parent() @test {
    Scene scene = make_scene(4);
    defer scene::destroy_scene(&scene);

    Node* parent = scene.add_node()!!;
    Node* child = scene.add_node(parent)!!;
    parent.local.position = { 5, 0, 0 };
    parent.local.rotation = quarter_turn_y();
    scene.update_world();

    Vec3 position = { -1, 4, 2 };
    Quat rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.7f);
    child.set_world_pose(position, rotation);
    scene.update_world();

    assert(close_vec3(child.world_position(), position));
    Quat world_rotation = maths::transform_from_mat4(child.world).rotation;
    assert(math::abs(world_rotation.v.dot(rotation.v)) > 1 - 1e-5);
}

fn void test_removal_frees_names_and_morph_weights() @test {
    TrackingAllocator tracker;
    tracker.init(mem);
    defer tracker.free();

    Scene scene = scene::create_scene(&tracker, { .max_nodes = 4 });
    Node* parent = scene.add_node(name: "parent")!!;
    Node* mesh_node = scene.add_mesh((GeometryId){}, (MaterialId){}, parent, "mesh")!!;
    scene.get(mesh_node, Mesh).morph_weights = alloc::new_array(scene.allocator, float, 3);
    scene.remove(mesh_node);
    scene::destroy_scene(&scene);

    assert(!tracker.has_leaks());
}

fn void test_destroy_scene_runs_remaining_hooks() @test {
    Scene scene = make_scene(4);

    HookRecord record;
    scene.set_remove_hook(Tag, &record_removal, &record);
    Node* a = scene.add_node()!!;
    Node* b = scene.add_node(a)!!;
    Node* c = scene.add_node()!!;
    scene.add(a, (Tag){ .label = 1 });
    scene.add(b, (Tag){ .label = 2 });
    scene.add(c, (Tag){ .label = 3 });
    scene::destroy_scene(&scene);

    assert(record.calls == 3);
    assert(scene.nodes.len == 0);
}

fn void test_add_camera_attaches_component() @test {
    Scene scene = make_scene(4);
    defer scene::destroy_scene(&scene);
    Node* node = scene.add_camera(camera::perspective_deg(60, 0.1f))!!;
    Camera* attached = scene.get(node, Camera);
    assert(attached != null);
    assert(close(attached.fov_y, (float)math::PI / 3));
    assert(attached.layers == camera::ALL_LAYERS);
    assert(scene.count(Camera) == 1);
}

fn void test_world_child_ignores_ancestors_and_parents_its_descendants() @test {
    Scene scene = make_scene(5);
    defer scene::destroy_scene(&scene);
    Node* holder = scene.add_node()!!;
    Node* independent = scene.add_node(holder)!!;
    Node* descendant = scene.add_node(independent)!!;
    holder.local.position = { 7, -3, 5 };
    holder.local.rotation = quarter_turn_y();
    holder.local.scale = { 2, 3, 0.5f };
    independent.transform_space = TransformSpace.WORLD;
    independent.local.position = { 1, 2, 3 };
    independent.local.rotation = quarter_turn_y();
    descendant.local.position = { 2, 0, 0 };
    scene.update_world();
    assert(close_vec3(independent.world_position(), { 1, 2, 3 }));
    assert(close_vec3(descendant.world_position(), { 1, 2, 1 }));

    Mat4 independent_before = independent.world;
    Mat4 descendant_before = descendant.world;
    holder.local.position = { -4, 8, -6 };
    holder.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.4f);
    holder.local.scale = { 4, 0.5f, 2 };
    scene.update_world();
    assert(close_mat4(independent.world, independent_before));
    assert(close_mat4(descendant.world, descendant_before));
}

fn void test_transform_space_reinterprets_the_authored_pose_on_update() @test {
    Scene scene = make_scene(3);
    defer scene::destroy_scene(&scene);
    Node* parent = scene.add_node()!!;
    Node* child = scene.add_node(parent)!!;
    parent.local.position = { 5, 0, 0 };
    child.local.position = { 1, 2, 3 };
    scene.update_world();
    assert(close_vec3(child.world_position(), { 6, 2, 3 }));

    child.transform_space = TransformSpace.WORLD;
    assert(close_vec3(child.world_position(), { 6, 2, 3 }));
    scene.update_world();
    assert(close_vec3(child.world_position(), { 1, 2, 3 }));
    child.transform_space = TransformSpace.PARENT;
    scene.update_world();
    assert(close_vec3(child.world_position(), { 6, 2, 3 }));
}

fn void test_world_child_keeps_hierarchy_visibility_and_removal() @test {
    Scene scene = make_scene(5);
    defer scene::destroy_scene(&scene);
    HookRecord record;
    scene.set_remove_hook(Tag, &record_removal, &record);
    Node* parent = scene.add_node()!!;
    Node* child = scene.add_node(parent)!!;
    Node* grandchild = scene.add_node(child)!!;
    Node* survivor = scene.add_node()!!;
    child.transform_space = TransformSpace.WORLD;
    scene.add(child, (Tag){ .label = 1 });
    scene.add(grandchild, (Tag){ .label = 2 });
    Entity child_id = child.id;
    Entity grandchild_id = grandchild.id;
    parent.visible = false;
    scene.update_world();
    assert(!child.visible_effective && !grandchild.visible_effective);
    assert(child.visible && grandchild.visible);
    parent.visible = true;
    scene.update_world();
    assert(child.visible_effective && grandchild.visible_effective);
    scene.remove(parent);
    assert(!scene.world.is_alive(child_id) && !scene.world.is_alive(grandchild_id));
    assert(scene.world.is_alive(survivor.id));
    assert(record.calls == 2);
}

fn void test_world_setters_ignore_a_sheared_ancestor_basis() @test {
    Scene scene = make_scene(4);
    defer scene::destroy_scene(&scene);
    Node* ancestor = scene.add_node()!!;
    Node* parent = scene.add_node(ancestor)!!;
    Node* child = scene.add_node(parent)!!;
    ancestor.local.rotation = quarter_turn_y();
    ancestor.local.scale = { 2, 3, 0.5f };
    parent.local.position = { 5, 1, -2 };
    parent.local.rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.4f);
    child.transform_space = TransformSpace.WORLD;
    child.local.scale = { 2, 3, 4 };
    scene.update_world();

    child.set_world_position({ -1, 4, 2 });
    scene.update_world();
    assert(close_vec3(child.world_position(), { -1, 4, 2 }));
    assert(close_vec3(child.local.scale, { 2, 3, 4 }));

    Quat rotation = quaternion::from_axis_angle{float}({ 1, 0, 0 }, 0.7f);
    child.set_world_pose({ 3, -2, 1 }, rotation);
    scene.update_world();
    assert(close_vec3(child.world_position(), { 3, -2, 1 }));
    assert(math::abs(child.local.rotation.v.dot(rotation.v)) > 1 - TOLERANCE);
    assert(close_vec3(child.local.scale, { 2, 3, 4 }));

    Vec3 target = { 6, 0, -1 };
    child.look_at(target);
    scene.update_world();
    Vec3 forward = maths::transform_dir(child.world, { 0, 0, -1 }).normalize();
    assert(close_vec3(forward, (target - child.world_position()).normalize()));
}

fn void test_world_reparent_retains_pose_for_both_keep_world_settings() @test {
    Scene scene = make_scene(4);
    defer scene::destroy_scene(&scene);
    Node* first = scene.add_node()!!;
    Node* second = scene.add_node()!!;
    Node* child = scene.add_node(first)!!;
    first.local.position = { 5, 1, -2 };
    first.local.scale = { 2, 3, 0.5f };
    second.local.position = { -4, 2, 7 };
    second.local.rotation = quarter_turn_y();
    child.transform_space = TransformSpace.WORLD;
    child.local.position = { 1, 2, 3 };
    child.local.rotation = quarter_turn_y();
    scene.update_world();
    Mat4 before = child.world;

    scene.reparent(child, second);
    scene.update_world();
    assert(child.parent == second && close_mat4(child.world, before));
    scene.reparent(child, first, keep_world: true);
    scene.update_world();
    assert(child.parent == first && close_mat4(child.world, before));
    assert(child.transform_space == TransformSpace.WORLD);
}

fn void test_shift_origin_moves_root_children_and_world_nodes_once() @test {
    Scene scene = make_scene(8);
    defer scene::destroy_scene(&scene);
    Vec3 offset = { 50176, 0, 50432 };
    Node* root_child = scene.add_node()!!;
    Node* nested = scene.add_node(root_child)!!;
    Node* grandchild = scene.add_node(nested)!!;
    Node* world_root_child = scene.add_node()!!;
    Node* world_nested = scene.add_node(nested)!!;
    root_child.local.position = { 50177.5f, 3, 50433.25f };
    nested.local.position = { 0.1f, 1, 2 };
    grandchild.local.position = { 0.3f, 0.2f, 0.7f };
    world_root_child.transform_space = TransformSpace.WORLD;
    world_root_child.local.position = { 50200, 5, 50500.5f };
    world_nested.transform_space = TransformSpace.WORLD;
    world_nested.local.position = { 50000.5f, 7, 50400 };
    scene.update_world();
    Node*[5] nodes = { root_child, nested, grandchild, world_root_child, world_nested };
    Mat4[5] before;
    Vec3[5] locals;
    foreach (index, node : nodes) {
        before[index] = node.world;
        locals[index] = node.local.position;
    }

    scene.shift_origin(offset);
    scene.update_world();

    assert(scene.world_shift == (double[<3>]){ 50176, 0, 50432 });
    assert(root_child.local.position == locals[0] - offset);
    assert(world_root_child.local.position == locals[3] - offset);
    assert(world_nested.local.position == locals[4] - offset);
    assert(nested.local.position == locals[1] && grandchild.local.position == locals[2]);
    foreach (index : (usz[]){ 0, 3, 4 }) {
        assert(nodes[index].world_position() == maths::translation(before[index]) - offset);
    }
    foreach (index : (usz[]){ 1, 2 }) {
        Vec3 expected = maths::translation(before[index]) - offset;
        Vec3 actual = nodes[index].world_position();
        assert(math::abs(actual.x - expected.x) <= 0.004f);
        assert(math::abs(actual.y - expected.y) <= 0.004f);
        assert(math::abs(actual.z - expected.z) <= 0.004f);
    }
}
