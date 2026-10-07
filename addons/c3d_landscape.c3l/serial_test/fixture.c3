module c3d_landscape_serial_test;

import c3d;
import c3d::asset;
import c3d::camera;
import c3d::describe;
import c3d::ecs;
import c3d::geometry;
import c3d::landscape @public;
import c3d::landscape::terrain;
import c3d::landscape::foliage;
import c3d::landscape::water;
import c3d::material;
import c3d::maths;
import c3d::scene;
import c3d::serial;
import std::math;

struct Fixture @private {
    AssetStore assets;
    Scene source;
    Scene destination;
    Node* root;
    Node* terrain_node;
    Node* foliage_node;
    Node* water_node;
}

struct Extra @private {
    uint value;
}

struct CopyFailure (Allocator) @private {
    Allocator backing;
    bool enabled;
    uint copies;
    uint failure;
}

fn void*? CopyFailure.acquire(
    &self,
    sz size,
    AllocInitType init_type,
    sz alignment,
) @dynamic {
    if (self.enabled && size > 64 && ++self.copies == self.failure) return mem::OUT_OF_MEMORY~;
    return self.backing.acquire(size, init_type, alignment);
}

fn void*? CopyFailure.resize(
    &self,
    void* pointer,
    sz size,
    sz alignment,
) @dynamic {
    return self.backing.resize(pointer, size, alignment);
}

fn void CopyFailure.release(&self, void* pointer, bool aligned) @dynamic {
    self.backing.release(pointer, aligned);
}

fn void register_scene(Scene* scene, AssetStore* assets) @private {
    terrain::register_terrain(scene, assets)!!;
    foliage::register_foliage(scene)!!;
    water::register_water(scene, assets)!!;
    scene.register(Extra)!!;
}

fn void create_fixture(
    Fixture* fixture,
    Allocator allocator = mem,
    uint capacity = 32,
    bool with_lod = true,
) @private {
    landscape::register_serial_codecs()!!;
    fixture.assets = asset::create_asset_store(mem, {
        .max_geometries = 8,
        .max_textures = 16,
        .max_materials = 16,
        .max_samplers = 8,
        .max_shaders = 4,
    });
    fixture.source = scene::create_scene(mem, { .max_nodes = 32 });
    fixture.destination = scene::create_scene(allocator, { .max_nodes = capacity });
    register_scene(&fixture.source, &fixture.assets);
    register_scene(&fixture.destination, &fixture.assets);
    MaterialId layer = fixture.assets.add_material(material::standard(), "layer")!!;
    GeometryId plant;
    @pool() {
        Geometry box = geometry::box(
            allocator: tmem,
            width: 0.2f,
            height: 1,
            depth: 0.2f,
        );
        plant = fixture.assets.add_geometry(&box, "plant")!!;
    };
    TextureId height;
    @pool() {
        char[] pixels = alloc::new_array(tmem, char, 129 * 129 * ushort::size);
        TextureDesc texture = material::texture_2d_desc(129, 129, R16_UINT);
        texture.generate_mips = false;
        height = fixture.assets.add_texture(texture, pixels, "height")!!;
    };
    char[4] density_pixels = { 255, 255, 255, 255 };
    TextureId density = fixture.assets.add_texture(
        desc: material::texture_2d_desc(1, 1, RGBA8_UNORM),
        pixels: density_pixels[..],
        key: "density",
    )!!;
    fixture.root = fixture.source.add_node(name: "landscape")!!;
    fixture.terrain_node = fixture.source.add_node(fixture.root, "ground")!!;
    fixture.foliage_node = fixture.source.add_node(fixture.root, "plants")!!;
    fixture.water_node = fixture.source.add_node(fixture.root, "water")!!;
    fixture.source.add_node(fixture.terrain_node, "authored-child")!!;
    TerrainDesc terrain_desc = terrain::default_terrain_desc();
    terrain_desc.height_map = height;
    terrain_desc.control_map = density;
    terrain_desc.cell_size = 1;
    terrain_desc.height_scale = 4;
    terrain_desc.layers[0] = layer;
    terrain_desc.lod_threshold = 123;
    terrain_desc.lod_hysteresis = 0.4f;
    terrain_desc.cast_shadow = false;
    terrain_desc.receive_shadow = false;
    terrain::attach_terrain(
        scene: &fixture.source,
        assets: &fixture.assets,
        node: fixture.terrain_node,
        desc: terrain_desc,
    )!!;
    LodLevel[2] levels = { { .part_count = 1, .min_screen_size = 0.1f }, { .first_part = 1, .part_count = 1 } };
    LodPart[2] parts;
    parts[..] = { .geometry = plant, .material = layer, .local = matrix::IDENTITY4 };
    parts[0].local.m00 = -1;
    parts[0].local.m01 = 0.25f;
    parts[0].local.m03 = 2;
    parts[0].local.m13 = 3;
    parts[0].local.m23 = -4;
    LodDesc lod = { .levels = levels[..], .parts = parts[..] };
    FoliageDesc plants = foliage::default_foliage_desc();
    plants.geometry = plant;
    plants.material = layer;
    plants.lod = with_lod ? &lod : null;
    plants.ground = fixture.terrain_node.id;
    plants.cell_size = 128;
    plants.rules = {
        .density_map = density,
        .density_channel = 2,
        .spacing = 32,
        .seed = 53,
        .max_slope = 1,
        .min_altitude = -7,
        .max_altitude = 20,
        .min_scale = 0.5f,
        .max_scale = 1.5f,
        .min_tint = { 0.1f, 0.2f, 0.3f },
        .max_tint = { 0.7f, 0.8f, 0.9f },
    };
    plants.sway = {
        .amplitude = 0.3f,
        .full_bend_speed = 7,
        .frequency = 0.4f,
        .lean = 0.2f,
        .wavelength = 5,
        .variation = 0.7f,
        .weight = VERTEX_ALPHA,
    };
    plants.fade = { .start = 12, .end = 22 };
    plants.cast_shadow = true;
    plants.receive_shadow = false;
    plants.trace = true;
    foliage::attach_foliage(
        scene: &fixture.source,
        assets: &fixture.assets,
        node: fixture.foliage_node,
        desc: plants,
    )!!;
    WaterDesc water_desc = water::default_water_desc();
    water_desc.extent = 4;
    water_desc.cell_size = 0.5f;
    if (!with_lod) {
        @pool() {
            Geometry surface = {
                .positions = alloc::new_array(tmem, Vec3, 3),
                .indices = alloc::new_array(tmem, uint, 3),
            };
            surface.positions[..] = ((Vec3[3]){ { 0, 0, 0 }, { 2, 0, 0 }, { 0, 0, 2 } })[..];
            surface.indices[..] = { 0, 2, 1 }[..];
            surface.finalize();
            water_desc.geometry = fixture.assets.add_geometry(&surface, "water-source")!!;
        };
    }
    water_desc.wave_count = 3;
    water_desc.waves[2] = {
        .amplitude = 0.04f, .wavelength = 2, .speed = -0.1f, .direction = { 0, 1 }, .steepness = 0.1f,
    };
    water_desc.absorption_color = { 0.2f, 0.4f, 0.6f };
    water_desc.absorption_distance = 3;
    water_desc.scatter_color = { 0.1f, 0.2f, 0.3f };
    water_desc.roughness = 0.2f;
    water_desc.refraction_strength = 0.03f;
    water_desc.reflection_distortion = 0.07f;
    water_desc.foam_depth = 0.8f;
    water_desc.foam_crest = 0.6f;
    water_desc.ripple_drift = 0.04f;
    water_desc.ripples = layer;
    water_desc.foam = layer;
    water_desc.march_reflections = false;
    water::attach_water(
        scene: &fixture.source,
        assets: &fixture.assets,
        node: fixture.water_node,
        desc: water_desc,
    )!!;
    fixture.source.update_world();
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
) @private {
    if (text_mode) return (char[])serial::write_subtree_text(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: root,
    )!;
    return serial::write_subtree(
        allocator: tmem,
        scene: scene,
        assets: assets,
        root: root,
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

fn Node* child_named(Node* root, String name) @private {
    for (Node* child = root.first_child; child; child = child.next_sibling) if (child.name == name) return child;
    unreachable();
}

fn void prepare_all(Scene* scene, AssetStore* assets, Node* root) @private {
    scene.update_world();
    terrain::prepare_subtree(scene, assets, root)!!;
    foliage::prepare_subtree(scene, assets, root)!!;
    water::prepare_subtree(scene, assets, root)!!;
}
