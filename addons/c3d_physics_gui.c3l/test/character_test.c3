module c3d_physics_gui_character_test @feat(C3D_PHYSICS_GUI & C3D_PHYSICS_GUI_CHARACTER);

import c3d;
import c3d::asset;
import c3d::character;
import c3d::gui @public;
import c3d::physics;
import c3d::scene;

fn void test_selection_blocks_include_characters() @test {
    AssetStore assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer asset::destroy_asset_store(&assets);
    Scene scene = scene::create_scene(mem, scene::default_scene_desc());
    defer scene::destroy_scene(&scene);
    physics::register_physics(&scene)!!;
    character::register_character(&scene)!!;

    Node* walker = scene.add_node(name: "walker")!!;
    scene.add_character(walker, character::default_character_desc())!!;
    Node* pusher = scene.add_node(name: "pusher")!!;
    CharacterDesc pushing = character::default_character_desc();
    pushing.push_bodies = true;
    scene.add_character(pusher, pushing)!!;

    PhysicsSelectionBlocks expected_walker = { .character = true };
    PhysicsSelectionBlocks expected_pusher = { .body = true, .character = true };
    assert(gui::physics_selection_blocks(&scene, walker.id) == expected_walker);
    assert(gui::physics_selection_blocks(&scene, pusher.id) == expected_pusher);
}
