module scene_example;

import std::io;
import std::math;
import c3d;
import c3d::maths;
import c3d::scene;

const uint NODE_CAPACITY @local = 16;

fn void print_position(String label, Node* node) @local {
    Vec3 position = node.world_position();
    io::printfn("  %s at (%.1f, %.1f, %.1f)", label, position.x, position.y, position.z);
}

fn int main() {
    Scene scene = scene::create_scene(mem, { .max_nodes = NODE_CAPACITY });
    defer scene::destroy_scene(&scene);

    Node* vehicle = scene.add_node(name: "vehicle")!!;
    Node* turret = scene.add_node(vehicle, "turret")!!;
    Node* barrel = scene.add_mesh((GeometryId){}, (MaterialId){}, turret, "barrel")!!;
    Node* crate = scene.add_mesh((GeometryId){}, (MaterialId){}, name: "crate")!!;
    scene.add_node(crate, "debris")!!;
    vehicle.local.position = { 2, 0, 0 };
    turret.local.position = { 0, 1, 0 };
    barrel.local.position = { 0, 0, 1 };
    scene.get(barrel, Mesh).morph_weights = alloc::new_array(scene.allocator, float, 2);

    io::printn("world after the first update");
    scene.update_world();
    print_position("turret", turret);
    print_position("barrel", barrel);

    io::printn("vehicle hidden");
    vehicle.visible = false;
    scene.update_world();
    io::printfn("  barrel visible %s, effective %s", barrel.visible, barrel.visible_effective);

    io::printn("vehicle shown and turned, barrel reparented to the root keeping its world");
    vehicle.visible = true;
    vehicle.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::PI / 2);
    scene.update_world();
    print_position("barrel before", barrel);
    scene.reparent(barrel, null, keep_world: true);
    scene.update_world();
    print_position("barrel after", barrel);

    io::printn("crate queued for removal while iterating meshes");
    scene.@each(Mesh; Entity entity, Mesh* mesh) {
        Node* node = scene.node(entity);
        if (node.name == "crate") scene.remove_later(node);
    };
    io::printfn("  crate alive before flush %s, meshes %d", scene.world.is_alive(crate.id), scene.count(Mesh));
    scene.flush_removals();
    io::printfn("  crate alive after flush %s, meshes %d", scene.world.is_alive(crate.id), scene.count(Mesh));
    if (catch scene.find("debris")) io::printn("  debris gone with its parent");
    return 0;
}
