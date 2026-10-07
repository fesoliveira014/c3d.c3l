module c3d_physics_serial_test;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::geometry;
import c3d::material;
import c3d::physics @public;
import c3d::scene;
import c3d::serial;
import std::math;

struct Fixture @private {
    AssetStore assets;
    Scene source;
    Scene destination;
    Node* root;
    GeometryId geometry;
    TextureId texture;
}

fn void create_fixture(
    Fixture* fixture,
    Allocator allocator = mem,
    uint capacity = 32,
) @private {
    physics::register_serial_codecs()!!;
    fixture.assets = asset::create_asset_store(mem, {
        .max_geometries = 8,
        .max_textures = 8,
        .max_materials = 4,
        .max_samplers = 8,
        .max_models = 4,
        .max_skeletons = 4,
        .max_clips = 4,
    });
    fixture.source = scene::create_scene(mem, { .max_nodes = 32 });
    fixture.destination = scene::create_scene(allocator, { .max_nodes = capacity });
    physics::register_physics(&fixture.source)!!;
    physics::register_physics(&fixture.destination)!!;
    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width: 1,
            height: 1,
            depth: 1,
        );
        fixture.geometry = fixture.assets.add_geometry(&box, "cube")!!;
    };
    ushort[4] heights = { 0, 100, 200, 65535 };
    TextureDesc texture = material::texture_2d_desc(2, 2, R16_UINT);
    texture.generate_mips = false;
    fixture.texture = fixture.assets.add_texture(texture, ((char*)&heights)[:heights.len * ushort::size], "heights")!!;
    fixture.root = fixture.source.add_node(name: "physics")!!;
}

fn void destroy_fixture(Fixture* fixture) @private {
    scene::destroy_scene(&fixture.destination);
    scene::destroy_scene(&fixture.source);
    asset::destroy_asset_store(&fixture.assets);
}

fn char[]? encode(
    Scene* scene,
    AssetStore* assets,
    Node* root,
    bool text_mode,
    serial::WriteOptions options = {},
) @private {
    if (text_mode) return (char[])serial::write_subtree_text(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: root,
        options: { .limits = serial::TEXT_LIMITS_DEFAULT, .diagnostic = options.diagnostic },
    )!;
    return serial::write_subtree(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: root,
        options: options,
    );
}

fn Node*? decode(
    Fixture* fixture,
    char[] bytes,
    bool text_mode,
    serial::ReadOptions options = serial::READ_OPTIONS_DEFAULT,
) @private {
    if (text_mode) return serial::read_subtree_text(
        scene: &fixture.destination,
        assets: &fixture.assets,
        text: (String)bytes,
        options: options,
    );
    return serial::read_subtree(
        scene: &fixture.destination,
        assets: &fixture.assets,
        bytes: bytes,
        options: options,
    );
}

fn PhysicsWorld create_world(Scene* scene, AssetStore* assets) @private {
    PhysicsDesc desc = physics::default_physics_desc();
    desc.tuning.gravity = {};
    desc.tuning.interpolate = false;
    return physics::create_physics_world(
        allocator: mem,
        assets: assets,
        scene: scene,
        desc: desc,
    )!!;
}

fn Node* add_sphere(
    Scene* scene,
    Node* parent,
    String name,
    BodyKind kind,
) @private {
    Node* node = scene.add_node(parent, name)!!;
    ColliderDesc collider = physics::default_collider_desc(SPHERE);
    collider.radius = 0.25f;
    scene.add_physics_body(node, physics::default_body_desc(kind), (&collider)[:1])!!;
    return node;
}
