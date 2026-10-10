module c3d_serial_all_test;

import c3d;
import c3d::anim;
import c3d::anim::ik;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::character;
import c3d::ecs;
import c3d::geometry;
import c3d::landscape;
import c3d::landscape::terrain;
import c3d::landscape::foliage @public;
import c3d::landscape::water;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::nav;
import c3d::particle @public;
import c3d::physics;
import c3d::physics::cloth;
import c3d::audio;
import c3d::scene;
import c3d::serial @public;
import std::io::path;
import std::math;

fn void assert_authoring(Fixture* fixture, Node* root) @private {
    Scene* scene = &fixture.destination;
    Node* values = child_named(root, "values");
    assert(c3d::same_id(scene.get(values, Mesh).geometry, fixture.box));
    assert(scene.get(values, Camera).near == 0.2f);
    assert(scene.get(values, Light).intensity == 2);
    assert(scene.get(values, ProbeVolume).counts == (uint[<3>]){ 3, 4, 5 });
    assert(scene.get(values, Atmosphere).planet_radius == light::ATMOSPHERE_EARTH.planet_radius);
    assert(scene.get(values, HeightFog).falloff == light::HEIGHT_FOG_DEFAULT.falloff);
    assert(scene.get(values, ReflectionProbe).half_extents == (Vec3){ 2, 3, 4 });
    assert(c3d::same_id(scene.get(values, Decal).material, fixture.material));
    InstancedMesh* batch = scene.get(child_named(root, "instances"), InstancedMesh);
    assert(batch.count == 1 && batch.transforms.len == 4);
    assert(batch.transforms[0].position == (Vec3){ 1, 2, 3 } && batch.colors[0].w == 0.8f);
    BillboardBatch* cards = scene.get(child_named(root, "billboards"), BillboardBatch);
    assert(cards.count == 1 && cards.billboards.len == 3 && cards.facing == DIRECTIONAL);
    assert(cards.billboards[0].rotation == 0.5f);
    LodGroupState* lod = scene.get(child_named(root, "lod"), LodGroup).state;
    assert(lod.desc.parts[0].local.m01 == 0.25f && lod.desc.parts[0].local.m03 == 2);
    Node* rig = child_named(root, "rig");
    ModelInstance* model = scene.get(rig, ModelInstance);
    assert(c3d::same_id(model.source, fixture.model) && model.nodes.len == 4);
    Node* skin = model.present_node(1);
    SkinBinding* binding = scene.get(skin, SkinBinding);
    assert(binding.joints[0] == model.present_node(2) && binding.joints[1] == model.present_node(3));
    Animator* animator = scene.get(rig, Animator);
    assert(animator.action_count == 1 && animator.action(animator.order[0]).speed == 0.5f);
    assert(animator.action(animator.order[0]).time == 0);
    Ragdoll* ragdoll = scene.get(skin, Ragdoll);
    assert(ragdoll.weight == 1.75f && ragdoll.bone_weights[1] == 1.5f && ragdoll.recoveries == 0);
    assert(ragdoll.bone_joints[1] == 1 && ragdoll.bone_nodes.len == 2);
    AnimatedCrowd* crowd = scene.get(child_named(root, "crowd"), AnimatedCrowd);
    assert(crowd.count == 1 && crowd.placements.len == 3 && crowd.colors[0].w == 0.8f);
    assert(crowd.start_times[0] == 0.125f && crowd.seeds[0].time == 0.125f && !crowd.is_prepared());
    Node* constraints = child_named(root, "constraints");
    Node* hip = child_named(constraints, "hip");
    IkChain* chain = scene.get(constraints, IkChain);
    assert(chain.joints[0] == hip && chain.weight == 0.6f && ik::ik_chain_valid(chain));
    FootIk* foot = scene.get(constraints, FootIk);
    assert(foot.leg.joints[0] == hip && foot.foot_height == 0.12f && !foot.grounded);
    LookAt* look = scene.get(constraints, LookAt);
    assert(look.joints[0] == hip && look.max_angle == 0.5f && ik::look_at_valid(look));
    Node* body = child_named(root, "body");
    PhysicsBody* request = scene.get(body, PhysicsBody);
    assert(request.body.name == "floating-body" && request.body.linear_damping == 0.2f && request.status == PENDING);
    assert(request.colliders.len == 1 && request.colliders[0].radius == 0.25f);
    PhysicsJoint* joint = scene.get(body, PhysicsJoint);
    assert(c3d::same_id(joint.desc.other, child_named(root, "contact").id) && joint.desc.distance.length == 1.25f);
    assert(scene.get(body, Wind).lift == 0.4f && scene.get(body, Force).local_point == (Vec3){ 7, 8, 9 });
    assert(scene.get(body, Buoyancy).fluid_density == 1025 && scene.get(body, Buoyancy).submerged_fraction == 0);
    Node* fabric = child_named(root, "fabric");
    Cloth* cloth = scene.get(fabric, Cloth);
    assert(!cloth.is_prepared() && c3d::same_id(cloth.authoring.source, fixture.box));
    assert(cloth.authoring.desc.pins == ((uint[3]){ 3, 1, 1 })[..]);
    assert(c3d::same_id(cloth.authoring.desc.colliders[0], child_named(root, "contact").id));
    assert(scene.has(fabric, NavSource) && c3d::same_id(scene.get(fabric, Mesh).geometry, fixture.box));
    Breakable* breakable = scene.get(child_named(root, "breakable"), Breakable);
    assert(!breakable.is_prepared() && breakable.state.pieces.len == 2 && breakable.state.desc.break_force == 123);
    Node* navigation = child_named(root, "navigation");
    assert(scene.get(navigation, NavSource).walkable && scene.get(navigation, NavSource).geometry.generation);
    assert(scene.get(navigation, NavVolume).area == 2);
    assert(scene.get(navigation, NavLink).user_id == 12345 && scene.get(navigation, NavLink).flags == 32769);
    assert(scene.get(navigation, NavObstacle).radius == 0.3f);
    Node* person = child_named(root, "character");
    assert(scene.get(person, NavAgent).params.max_speed == 3 && scene.get(person, NavAgent).target == (Vec3){ 6, 0, 3 });
    assert(scene.get(person, Character).desc.radius == 0.3f && scene.get(person, Character).desc.push_bodies);
    assert(!scene.get(person, NavDriven).traversal.active && scene.get(person, NavAgent).driven);
    Node* ground = child_named(root, "terrain");
    assert(scene.get(ground, Terrain).desc.height_scale == 4 && scene.get(ground, Terrain).desc.lod_threshold == 123);
    assert(!terrain::is_prepared(scene, ground));
    Node* plants = child_named(root, "foliage");
    assert(scene.get(plants, Foliage).desc.rules.seed == 53 && c3d::same_id(scene.get(plants, Foliage).desc.ground, ground.id));
    assert(!foliage::is_prepared(scene, plants));
    Node* lake = child_named(root, "water");
    assert(scene.get(lake, Water).desc.roughness == 0.2f && !water::is_prepared(scene, lake));
    ParticleSystem* particles = scene.get(child_named(root, "particles"), ParticleSystem);
    assert(particles.desc.capacity == 7 && particles.desc.seed == 12345 && !particles.emitting);
    assert(!particles.is_prepared() && particles.alive == 0);
    AudioEmitter* emitter = scene.get(child_named(root, "sound"), AudioEmitter);
    assert(c3d::same_id(emitter.clip, fixture.clip) && emitter.bus == audio::MUSIC_BUS && emitter.pitch == 1.5f);
    assert(emitter.volume == 0.75f && emitter.max_distance == 40 && emitter.looping && emitter.playing);
    assert(scene.get(child_named(root, "ears"), AudioListener).active);
}

fn char[] encode(
    Scene* scene,
    AssetStore* assets,
    Node* root,
    bool text_mode,
) @private {
    if (text_mode) return (char[])serial::write_subtree_text(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: root,
    )!!;
    return serial::write_subtree(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: root,
    )!!;
}

fn Node* decode(Fixture* fixture, char[] bytes, bool text_mode) @private {
    if (text_mode) return serial::read_subtree_text(&fixture.destination, &fixture.assets, (String)bytes)!!;
    return serial::read_subtree(&fixture.destination, &fixture.assets, bytes)!!;
}

fn void test_all_authored_components_round_trip_and_restore_snapshot_in_both_formats() @test {
    foreach (text_mode : (bool[2]){ false, true }) {
        @pool() {
            Fixture fixture;
            create_fixture(&fixture);
            defer destroy_fixture(&fixture);
            Systems source_systems;
            create_systems(&source_systems, &fixture.source, &fixture.assets);
            defer destroy_systems(&source_systems);
            prepare_scene(
                systems: &source_systems,
                scene: &fixture.source,
                assets: &fixture.assets,
                audio: &fixture.source_audio,
                root: fixture.source.root,
            );
            assert_presence(&fixture.source, true);
            anim::update(&fixture.assets, &fixture.source, 0.25f);
            anim::crowd_update(&fixture.assets, &fixture.source, 0.5f);
            fixture.source.update_world();
            uint source_available_nodes = fixture.source.world.entities.free_count;
            char[] bytes = encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.source.root,
                text_mode: text_mode,
            );
            Node* restored = decode(&fixture, bytes, text_mode);
            assert_presence(&fixture.destination, false);
            assert_authoring(&fixture, restored);
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            ));
            Node* values = child_named(restored, "values");
            fixture.destination.get(values, Light).intensity = 99;
            fixture.destination.get(values, Camera).near = 4;
            fixture.destination.get(child_named(restored, "particles"), ParticleSystem).emitting = true;
            fixture.destination.get(child_named(restored, "terrain"), Terrain).desc.height_scale = 17;
            fixture.destination.get(child_named(restored, "body"), PhysicsBody).body.linear_damping = 0.9f;
            assert(bytes != encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            ));
            fixture.destination.remove(restored);
            restored = decode(&fixture, bytes, text_mode);
            assert_presence(&fixture.destination, false);
            assert_authoring(&fixture, restored);
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            ));
            Systems loaded_systems;
            create_systems(&loaded_systems, &fixture.destination, &fixture.assets);
            defer destroy_systems(&loaded_systems);
            prepare_scene(
                systems: &loaded_systems,
                scene: &fixture.destination,
                assets: &fixture.assets,
                audio: &fixture.destination_audio,
                root: restored,
            );
            assert_presence(&fixture.destination, true);
            assert(fixture.destination.get(child_named(restored, "fabric"), Cloth).is_prepared());
            assert(fixture.destination.get(child_named(restored, "breakable"), Breakable).is_prepared());
            assert(fixture.destination.get(child_named(restored, "crowd"), AnimatedCrowd).is_prepared());
            assert(bytes == encode(
                scene: &fixture.destination,
                assets: &fixture.assets,
                root: restored,
                text_mode: text_mode,
            ));
            Animator* source = fixture.source.get(child_named(fixture.source.root, "rig"), Animator);
            assert(source.action(source.order[0]).time == 0.125f);
            assert(fixture.source.world.entities.free_count == source_available_nodes);
            assert(bytes == encode(
                scene: &fixture.source,
                assets: &fixture.assets,
                root: fixture.source.root,
                text_mode: text_mode,
            ));
        };
    }
}
