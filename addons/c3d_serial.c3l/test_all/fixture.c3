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
import c3d::landscape::foliage;
import c3d::landscape::water;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::nav;
import c3d::particle;
import c3d::physics;
import c3d::physics::cloth;
import c3d::scene;
import c3d::serial;
import std::io::path;
import std::math;

struct Fixture @private {
    AssetStore assets;
    Scene source;
    Scene destination;
    GeometryId box;
    MaterialId material;
    ModelId model;
}

struct Systems @private {
    PhysicsWorld physics;
    CharacterSystem characters;
    NavBuilder builder;
    NavMesh mesh;
    nav::Crowd crowd;
}

fn void register_codecs() @private {
    serial::register_core_codecs()!!;
    physics::register_serial_codecs()!!;
    nav::register_serial_codecs()!!;
    character::register_serial_codecs()!!;
    landscape::register_serial_codecs()!!;
    particle::register_serial_codecs()!!;
}

fn void register_scene(Scene* scene, AssetStore* assets) @private {
    physics::register_physics(scene)!!;
    nav::register_nav(scene)!!;
    character::register_character(scene)!!;
    character::register_nav_driven(scene)!!;
    terrain::register_terrain(scene, assets)!!;
    foliage::register_foliage(scene)!!;
    water::register_water(scene, assets)!!;
    particle::register_particles(scene)!!;
}

fn void create_fixture(Fixture* fixture) @private {
    register_codecs();
    fixture.assets = asset::create_asset_store(mem, {
        .max_geometries = 64, .max_textures = 32, .max_materials = 64,
        .max_samplers = 16, .max_models = 8, .max_skeletons = 8,
        .max_clips = 16, .max_shaders = 8,
    });
    fixture.source = scene::create_scene(mem, { .max_nodes = 256 });
    fixture.destination = scene::create_scene(mem, { .max_nodes = 256 });
    register_scene(&fixture.source, &fixture.assets);
    register_scene(&fixture.destination, &fixture.assets);
    Geometry box = geometry::box(
        allocator: tmem,
        width: 1,
        height: 1,
        depth: 1,
    );
    fixture.box = fixture.assets.add_geometry(&box, "box")!!;
    fixture.material = fixture.assets.add_material(material::standard(), "material")!!;
    Path here = path::tnew($$FILEPATH)!!;
    String filename = (String)here.parent()!!.tappend("../../../test/fixtures/gltf", "skin.gltf")!!;
    fixture.model = gltf::load_model(&fixture.assets, filename)!!;
    add_core(fixture);
    add_physics(fixture);
    add_navigation(fixture);
    add_landscape(fixture);
    fixture.source.update_world();
}

fn void destroy_fixture(Fixture* fixture) @private {
    scene::destroy_scene(&fixture.destination);
    scene::destroy_scene(&fixture.source);
    asset::destroy_asset_store(&fixture.assets);
}

fn void add_core(Fixture* fixture) @private {
    Scene* scene = &fixture.source;
    Node* values = scene.add_mesh(geometry: fixture.box, material: fixture.material, name: "values")!!;
    scene.add(values, camera::perspective_deg(50, 0.2f));
    scene.add(values, light::directional({ 0.4f, 0.5f, 0.8f }, 2));
    scene.add(values, light::probe_volume({ 3, 4, 5 }, { 3, 4, 5 }));
    scene.add(values, light::ATMOSPHERE_EARTH);
    scene.add(values, light::HEIGHT_FOG_DEFAULT);
    scene.add(values, light::reflection_probe({ 2, 3, 4 }, {}));
    scene.add(values, scene::default_decal_desc(fixture.material).decal);
    Transform[1] placements = { maths::TRANSFORM_IDENTITY };
    placements[0].position = { 1, 2, 3 };
    Vec4[1] colors = { { 0.2f, 0.4f, 0.6f, 0.8f } };
    scene.add_instanced_mesh(
        geometry: fixture.box,
        material: fixture.material,
        capacity: 4,
        transforms: &placements,
        colors: &colors,
        name: "instances",
    )!!;
    Billboard[1] cards = { scene::BILLBOARD_DEFAULT };
    cards[0].rotation = 0.5f;
    scene.add_billboards(
        material: fixture.material,
        capacity: 3,
        billboards: &cards,
        facing: DIRECTIONAL,
        name: "billboards",
    )!!;
    Mat4 basis = matrix::IDENTITY4;
    basis.m01 = 0.25f;
    basis.m03 = 2;
    LodPart[1] parts = { { .geometry = fixture.box, .material = fixture.material, .local = basis } };
    LodLevel[1] levels = { { .part_count = 1 } };
    scene.add_lod_group(
        assets: &fixture.assets, desc: { .parts = &parts, .levels = &levels },
        name: "lod",
    )!!;
    Node* rig = model::instantiate(
        assets: &fixture.assets,
        scene: scene,
        model: fixture.model,
        name: "rig",
    )!!;
    ModelInstance* instance = scene.get(rig, ModelInstance);
    Animator* animator = anim::add_animator(scene, rig);
    AnimationActionId action = animator.play(&fixture.assets, instance.clips[0])!!;
    animator.action(action).speed = 0.5f;
    scene.update_world();
    RagdollBone[2] bones = { physics::default_ragdoll_bone(0), physics::default_ragdoll_bone(1) };
    bones[0].radius = 0.1f;
    bones[1].radius = 0.1f;
    bones[1].length = 1;
    RagdollDesc ragdoll = physics::default_ragdoll_desc();
    ragdoll.bones = &bones;
    Node* skin = instance.present_node(1);
    scene.build_ragdoll(assets: &fixture.assets, skin_node: skin, desc: ragdoll)!!;
    scene.get(skin, Ragdoll).weight = 1.75f;
    scene.get(skin, Ragdoll).bone_weights[1] = 1.5f;
    CrowdInstance[1] people = { {
        .placement = maths::TRANSFORM_IDENTITY,
        .pose = { .clip = instance.clips[0], .time = 0.125f, .speed = 0.5f, .loop = true },
        .color = colors[0],
    } };
    Node* crowd = scene.add_node(name: "crowd")!!;
    model::attach_crowd(
        assets: &fixture.assets,
        scene: scene,
        node: crowd,
        model: fixture.model,
        capacity: 3,
        pose_bounds: { .min = { -1, -1, -1 }, .max = { 1, 1, 1 } },
        instances: &people,
        trace: true,
    )!!;
    Node* constraints = scene.add_node(name: "constraints")!!;
    Node* hip = scene.add_node(constraints, "hip")!!;
    Node* knee = scene.add_node(hip, "knee")!!;
    Node* ankle = scene.add_node(knee, "ankle")!!;
    knee.local.position = { 0, -1, 0 };
    ankle.local.position = { 0, -1, 0 };
    Node* target = scene.add_node(constraints, "target")!!;
    target.local.position = { 1, -1, 0 };
    IkChain chain = ik::ik_chain(
        root: hip,
        middle: knee,
        end: ankle,
        target: target,
    );
    chain.weight = 0.6f;
    scene.add(constraints, chain);
    FootIk foot = ik::foot_ik(
        hip: hip,
        knee: knee,
        ankle: ankle,
        target: target,
    );
    foot.foot_height = 0.12f;
    foot.grounded = true;
    scene.add(constraints, foot);
    LookAt look = ik::look_at({ hip, knee, ankle }, target, { 0, -1, 0 });
    look.max_angle = 0.5f;
    scene.add(constraints, look);
}

fn void add_physics(Fixture* fixture) @private {
    Scene* scene = &fixture.source;
    Node* anchor = scene.add_node(name: "contact")!!;
    ColliderDesc collider = physics::default_collider_desc(SPHERE);
    collider.radius = 0.25f;
    scene.add_physics_body(anchor, physics::default_body_desc(STATIC), (&collider)[:1])!!;
    Node* body = scene.add_node(name: "body")!!;
    BodyDesc body_desc = physics::default_body_desc(DYNAMIC);
    body_desc.name = "floating-body";
    body_desc.linear_damping = 0.2f;
    scene.add_physics_body(body, body_desc, (&collider)[:1])!!;
    JointDesc joint = physics::default_joint_desc(DISTANCE, anchor.id);
    joint.other = anchor.id;
    joint.distance.length = 1.25f;
    scene.add_physics_joint(body, joint)!!;
    scene.add(body, (Wind){ .velocity = { 1, 2, 3 }, .drag = 0.3f, .lift = 0.4f, .max_speed = 8 });
    scene.add(body, (Force){ .force = { 4, 5, 6 }, .local_point = { 7, 8, 9 } });
    scene.add(body, (Buoyancy){ .fluid_density = 1025, .linear_drag = 7 });
    Node* fabric = scene.add_mesh(geometry: fixture.box, material: fixture.material, name: "fabric")!!;
    ClothDesc cloth = cloth::default_cloth_desc();
    uint[3] pins = { 3, 1, 1 };
    cloth.pins = &pins;
    cloth.colliders = (&anchor.id)[:1];
    cloth.stretch_stiffness = 0.75f;
    scene.attach_cloth(assets: &fixture.assets, node: fabric, desc: cloth)!!;
    scene.add_nav_source(fabric)!!;
    Node* breakable = scene.add_node(name: "breakable")!!;
    BreakablePieceView[2] pieces;
    foreach (index, &piece : pieces) {
        Node* node = scene.add_mesh(
            geometry: fixture.box,
            material: fixture.material,
            parent: breakable,
            name: index ? "right" : "left",
        )!!;
        node.local.position.x = (float)index;
        *piece = { .node = node.id, .hulls = (&fixture.box)[:1], .rest_frame = node.local };
    }
    BreakableDesc fracture = physics::default_breakable_desc();
    fracture.break_force = 123;
    scene.attach_breakable_pieces(
        assets: &fixture.assets,
        root: breakable,
        pieces: &pieces,
        desc: fracture,
    )!!;
}

fn void add_navigation(Fixture* fixture) @private {
    Scene* scene = &fixture.source;
    Geometry floor = geometry::plane(
        allocator: tmem,
        width: 20,
        depth: 20,
        segments_x: 1,
        segments_z: 1,
    );
    GeometryId floor_id = fixture.assets.add_geometry(&floor, "floor")!!;
    Node* ground = scene.add_node(name: "navigation")!!;
    scene.add_nav_source(ground, floor_id)!!;
    scene.add_nav_volume(ground, {
        .kind = BOX, .area = 2, .box = { .min = { -2, -1, -2 }, .max = { 2, 2, 2 } },
    })!!;
    scene.add_nav_link(ground, {
        .start = { -5, 0, -5 }, .end = { 5, 0, 5 }, .radius = 0.5f,
        .bidirectional = true, .area = 3, .flags = 32769, .user_id = 12345,
    })!!;
    scene.add_nav_obstacle(ground, { .kind = CYLINDER, .position = { -3, 0, -3 }, .radius = 0.3f, .height = 1 })!!;
    Node* person = scene.add_node(name: "character")!!;
    CharacterDesc capsule = character::default_character_desc();
    capsule.radius = 0.3f;
    capsule.half_height = 0.7f;
    capsule.push_bodies = true;
    scene.add_character(person, capsule)!!;
    NavAgentParams agent = nav::default_nav_agent_params();
    agent.max_speed = 3;
    agent.height = 1.7f;
    scene.add_nav_agent(person, agent)!!;
    scene.add_nav_driven(person)!!;
    scene.set_nav_target(person, { 6, 0, 3 });
}

fn void add_landscape(Fixture* fixture) @private {
    Scene* scene = &fixture.source;
    char[] pixels = alloc::new_array(tmem, char, 129 * 129 * ushort::size);
    TextureDesc height_desc = material::texture_2d_desc(129, 129, R16_UINT);
    height_desc.generate_mips = false;
    TextureId height = fixture.assets.add_texture(height_desc, pixels, "height")!!;
    char[4] density_pixel = { 255, 255, 255, 255 };
    TextureId density = fixture.assets.add_texture(material::texture_2d_desc(1, 1, RGBA8_UNORM), &density_pixel, "density")!!;
    Node* ground = scene.add_node(name: "terrain")!!;
    TerrainDesc terrain = terrain::default_terrain_desc();
    terrain.height_map = height;
    terrain.cell_size = 1;
    terrain.layers[0] = fixture.material;
    terrain.height_scale = 4;
    terrain.lod_threshold = 123;
    terrain::attach_terrain(
        scene: scene,
        assets: &fixture.assets,
        node: ground,
        desc: terrain,
    )!!;
    Node* plants = scene.add_node(name: "foliage")!!;
    FoliageDesc foliage = foliage::default_foliage_desc();
    foliage.geometry = fixture.box;
    foliage.material = fixture.material;
    foliage.ground = ground.id;
    foliage.cell_size = 128;
    foliage.rules.density_map = density;
    foliage.rules.spacing = 32;
    foliage.rules.seed = 53;
    foliage.rules.max_slope = 1;
    foliage::attach_foliage(
        scene: scene,
        assets: &fixture.assets,
        node: plants,
        desc: foliage,
    )!!;
    Node* lake = scene.add_node(name: "water")!!;
    WaterDesc water = water::default_water_desc();
    water.extent = 4;
    water.cell_size = 0.5f;
    water.roughness = 0.2f;
    water::attach_water(
        scene: scene,
        assets: &fixture.assets,
        node: lake,
        desc: water,
    )!!;
    Node* emitter = scene.add_node(name: "particles")!!;
    ParticleSystemDesc particles = particle::default_particle_system_desc();
    particles.capacity = 7;
    particles.seed = 12345;
    particles.material = fixture.material;
    particles.geometry = fixture.box;
    particles.rate = 7;
    scene.attach_particle_system(emitter, particles)!!;
    scene.get(emitter, ParticleSystem).emitting = false;
}

fn void create_systems(Systems* systems, Scene* scene, AssetStore* assets) @private {
    PhysicsDesc physics = physics::default_physics_desc();
    physics.tuning.gravity = {};
    physics.tuning.interpolate = false;
    systems.physics = physics::create_physics_world(
        allocator: mem,
        assets: assets,
        scene: scene,
        desc: physics,
    )!!;
    systems.characters = character::create_character_system(mem, &systems.physics, scene)!!;
    NavBuilderDesc navigation = nav::default_nav_builder_desc({ .min = { -10, -1, -10 }, .max = { 10, 4, 10 } });
    navigation.cache_layers = true;
    systems.builder = nav::create_nav_builder(mem, scene, navigation)!!;
    systems.mesh = nav::create_nav_mesh_for(mem, &systems.builder)!!;
    systems.crowd = nav::create_crowd(
        allocator: mem,
        desc: { .max_agents = 4, .max_agent_radius = 1 },
        mesh: &systems.mesh,
        scene: scene,
    )!!;
}

fn void destroy_systems(Systems* systems) @private {
    nav::destroy_crowd(&systems.crowd);
    nav::destroy_nav_mesh(&systems.mesh);
    nav::destroy_nav_builder(&systems.builder);
    character::destroy_character_system(&systems.characters);
    physics::destroy_physics_world(&systems.physics);
}

fn void prepare_scene(Systems* systems, Scene* scene, AssetStore* assets, Node* root) @private {
    scene.update_world();
    terrain::prepare_subtree(scene, assets, root)!!;
    foliage::prepare_subtree(scene, assets, root)!!;
    water::prepare_subtree(scene, assets, root)!!;
    particle::prepare_subtree(scene, root)!!;
    model::prepare_crowd_subtree(assets, scene, root)!!;
    systems.physics.update(0);
    cloth::prepare_subtree(scene, assets, root)!!;
    systems.physics.prepare_breakable_subtree(root)!!;
    NavSyncResult result = nav::nav_sync(
        builder: &systems.builder,
        mesh: &systems.mesh,
        scene: scene,
        assets: assets,
        budget: 32,
    );
    assert(result.failed == 0 && result.pending == 0);
    nav::crowd_update(scene, &systems.crowd, 0.01f);
}

fn Node* child_named(Node* root, String name) @private {
    for (Node* child = root.first_child; child; child = child.next_sibling) if (child.name == name) return child;
    unreachable("Missing named fixture node.");
}
