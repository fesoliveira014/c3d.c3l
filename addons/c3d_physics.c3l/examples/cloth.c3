module cloth_example;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::asset::gltf;
import c3d::camera;
import c3d::debug;
import c3d::geometry;
import c3d::gui;
import c3d::light;
import c3d::material;
import c3d::maths;
import c3d::model;
import c3d::physics;
import c3d::physics::cloth;
import c3d::platform;
import c3d::render;
import c3d::scene;
import imgui;
import ragdoll_bones;
import std::io;
import std::io::file;
import std::math;
import std::math::quaternion;
import std::sort;
import std::time;
import std::time::clock;

alias Quat @local = Quaternionf;

const uint WIDTH @local = 1280;
const uint HEIGHT @local = 720;
const uint SCENE_NODE_CAPACITY @local = 256; // character joints, ragdoll bones, level
const uint FLAG_COLUMNS @local = 24;
const uint FLAG_ROWS @local = 16;
const uint BENCHMARK_CELLS @local = 32; // a 33x33-vertex flag at the default 4x8 solver settings
const float FLAG_WIDTH @local = 1.8f;
const float FLAG_HEIGHT @local = 1.2f;
const float POLE_HEIGHT @local = 4;
const float POLE_RADIUS @local = 0.05f;
const Vec3 POLE_POSITION @local = { 0.6f, 0, 0 };
const uint CAPE_COLUMNS @local = 12;
const uint CAPE_ROWS @local = 22;
const float CAPE_WIDTH @local = 0.5f;
const float CAPE_LENGTH @local = 0.95f;
const float CAPE_BACK_OFFSET @local = 0.17f; // metres behind the chest joint; clears the 0.13 m chest capsule
const float CAPE_SHOULDER_HEIGHT @local = 0.12f; // metres above the chest joint
const String CAPE_JOINT @local = "DEF-spine.003";
const float CAPE_THICKNESS @local = 0.02f; // metres; keeps the cape off the skin that lies outside the bone capsules
const Vec3 CHARACTER_POSITION @local = { -1.4f, 0, 0.6f };
const Vec3 CHARACTER_FACING @local = { -0.45f, 0, -1 }; // three-quarter back view from the camera
const String MODEL_PATH @local = "../../examples/assets/quaternius/AnimationLibrary_Godot.glb";
const String WALK_CLIP @local = "Walk_Loop";
const int RAGDOLL_GROUP @local = -1; // bones never collide with each other; joints hold them apart
const float DRIVE_HERTZ @local = 6;
const float DRIVE_DAMPING @local = 1;
const float BLEND_OUT_SECONDS @local = 0.8f;
const float AIR_RESPONSE @local = 2.5f; // per second: particle acceleration per m/s of normal wind, at any resolution
const float DEFAULT_WIND_SPEED @local = 6;
const float DEFAULT_WIND_HEADING @local = 35; // degrees off the flag plane; drag acts on the normal component only
const float GUST_SHARE @local = 0.35f; // fraction of the speed a gust adds or removes
const float GUST_RATE @local = 0.7f; // radians per second
const uint WARMUP_FRAMES @local = 120; // two simulated seconds settle the cloth before measuring
const uint MEASURED_FRAMES @local = 600;
const float STEP_SECONDS @local = 1.0f / 60;
const double NANOSECONDS_PER_MILLISECOND @local = 1_000_000;
const double PERCENTILE_95 @local = 0.95;
const uint CAPTURE_CHANNELS @local = 4;

enum Scenario @local {
    FLAG,
    CAPE,
    BOTH,
    CONTACTS,
    FOLD,
    FAST,
}

const String[Scenario::len] SCENARIO_NAMES @local = { "flag", "cape", "both", "contacts", "fold", "fast" };

struct Options @local {
    bool      benchmark;
    bool      still;
    bool      whole_publication;
    bool      ragdoll;
    bool      traced;
    bool      validation;
    TraceKind trace_kind;
    Scenario  scenario;
    uint      frames;
    String    capture_path;
}

struct Series @local {
    double total;
    double peak;
}

fn void Series.add(&self, double value) {
    self.total += value;
    self.peak = math::max(self.peak, value);
}

struct Character @local {
    Node* root;
    Node* skin;
    Node* cape;
    bool  ragdoll;
}

struct Demo @local {
    AssetStore   assets;
    Scene        scene;
    PhysicsWorld physics;
    Scenario     scenario;
    bool         simulated;
    bool         traced;
    Node*        flag;
    uint         flag_columns;
    uint         flag_rows;
    Character    character;
    Node*        fold;
    Node*        fast;
    Node*        fast_body;
    uint         fast_frame;
    uint         fast_impacts;
    Node*[6]     drapes;
    Entity[6]    drape_bodies;
    Node*        camera;
    float        wind_speed;
    float        wind_heading;
    bool         gusts;
    bool         whole_publication;
}

struct Controls @local {
    bool taa;
    bool motion_blur;
    bool colliders;
    bool ragdoll;
    bool reset;
}

fn Geometry cloth_grid(
    Allocator allocator,
    uint columns,
    uint rows,
    float width,
    float height,
) @local {
    uint stride = columns + 1;
    Geometry grid = {
        .positions = alloc::new_array(allocator, Vec3, (sz)(stride * (rows + 1))),
        .uv0       = alloc::new_array(allocator, Vec2, (sz)(stride * (rows + 1))),
        .indices   = alloc::new_array(allocator, uint, (sz)(6 * columns * rows)),
    };
    for (uint row = 0; row <= rows; row++) {
        for (uint column = 0; column <= columns; column++) {
            float u = (float)column / columns;
            float v = (float)row / rows;
            grid.positions[row * stride + column] = { u * width, -v * height, 0 };
            grid.uv0[row * stride + column] = { u, v };
        }
    }
    usz next;
    for (uint row = 0; row < rows; row++) {
        for (uint column = 0; column < columns; column++) {
            uint top_left = row * stride + column;
            uint bottom_left = top_left + stride;
            uint[6] corners = { top_left, bottom_left, top_left + 1, top_left + 1, bottom_left, bottom_left + 1 };
            grid.indices[next:6] = corners[..];
            next += 6;
        }
    }
    grid.finalize();
    return grid;
}

fn MaterialId? cloth_material(AssetStore* assets, Vec4 color) @local {
    MaterialCommon two_sided = material::MATERIAL_COMMON_DEFAULT;
    two_sided.double_sided = true;
    return assets.add_material(material::standard({ .base_color = color, .roughness = 0.8f }, two_sided));
}

// Particles have unit mass, so drag scales with vertex density to keep the response resolution-independent.
fn Wind grid_wind(
    uint columns,
    uint rows,
    float width,
    float height,
) @local {
    return { .drag = AIR_RESPONSE * (float)((columns + 1) * (rows + 1)) / (width * height) };
}

fn void? build_flag(Demo* demo) @local {
    MaterialId flag_material = cloth_material(&demo.assets, { 0.75f, 0.12f, 0.1f, 1 })!;
    MaterialId pole_material = demo.assets.add_material(material::standard({
        .base_color = { 0.55f, 0.55f, 0.58f, 1 }, .roughness = 0.4f, .metallic = 1,
    }))!;
    GeometryId flag_geometry;
    GeometryId pole_geometry;
    @pool() {
        Geometry flag = cloth_grid(
            allocator: tmem,
            columns:   demo.flag_columns,
            rows:      demo.flag_rows,
            width:     FLAG_WIDTH,
            height:    FLAG_HEIGHT,
        );
        flag_geometry = demo.assets.add_geometry(&flag, "cloth/flag")!;
        Geometry pole = geometry::cylinder(
            allocator:     tmem,
            radius_top:    POLE_RADIUS,
            radius_bottom: POLE_RADIUS,
            height:        POLE_HEIGHT,
        );
        pole_geometry = demo.assets.add_geometry(&pole, "cloth/pole")!;
    };
    Node* pole = demo.scene.add_mesh(pole_geometry, pole_material, name: "pole")!;
    pole.local.position = POLE_POSITION + (Vec3){ 0, POLE_HEIGHT * 0.5f, 0 };
    demo.flag = demo.scene.add_mesh(flag_geometry, flag_material, name: "flag")!;
    demo.flag.local.position = POLE_POSITION + (Vec3){ POLE_RADIUS, POLE_HEIGHT - 0.1f, 0 };
    demo.scene.get(demo.flag, scene::Mesh).trace = demo.traced;
    demo.scene.add(demo.flag, grid_wind(
        columns: demo.flag_columns,
        rows:    demo.flag_rows,
        width:   FLAG_WIDTH,
        height:  FLAG_HEIGHT,
    ));
}

fn ClipId? find_clip(AssetStore* assets, ClipId[] clips, String name) @local {
    foreach (clip : clips) {
        if (assets.clip(clip).data.name == name) return clip;
    }
    return NOT_FOUND~;
}

fn Vec3? joint_position(Node*[] joints, Skeleton* skeleton, String name) @local {
    return maths::translation(joints[skeleton.find_joint(name)!].world);
}

fn void? build_character(Demo* demo) @local {
    AssetStore* assets = &demo.assets;
    Scene* scene = &demo.scene;
    Character* character = &demo.character;
    ModelId model = gltf::load_model(assets, MODEL_PATH)!;
    character.root = model::instantiate(assets, scene, model, name: "character")!;
    ModelInstance* instance = scene.get(character.root, ModelInstance);
    for (usz node_index = 0; node_index < instance.nodes.len; node_index++) {
        Node* node = instance.present_node(node_index);
        if (!node) continue;
        if (scene.has(node, SkinBinding)) character.skin = node;
    }
    if (!character.skin) return NOT_FOUND~;
    ClipId walk = find_clip(assets, instance.clips, WALK_CLIP)!;
    anim::add_animator(scene, character.root).play(assets, walk)!;
    anim::update(assets, scene, 0);
    scene.update_world();

    Node*[] joints = scene.get(character.skin, SkinBinding).joints;
    Skeleton* skeleton = &assets.skeleton(scene.get(character.skin, SkinBinding).skeleton).data;
    Vec3 forward = joint_position(joints, skeleton, "DEF-toe.L")! - joint_position(joints, skeleton, "DEF-foot.L")!;
    Vec3 facing = CHARACTER_FACING.normalize();
    float turn = math::atan2(facing.x, facing.z) - math::atan2(forward.x, forward.z);
    character.root.local.position = CHARACTER_POSITION;
    character.root.local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, turn);
    scene.update_world();

    RagdollBone[ragdoll_bones::RIGIFY_BONE_COUNT] bones;
    ragdoll_bones::rigify_bones(
        skeleton:      skeleton,
        bones:         bones[..],
        drive_hertz:   DRIVE_HERTZ,
        drive_damping: DRIVE_DAMPING,
    )!;
    RagdollDesc desc = physics::default_ragdoll_desc();
    desc.bones = bones[..];
    desc.filter.group = RAGDOLL_GROUP;
    scene.build_ragdoll(assets, character.skin, desc)!;
    demo.physics.update(0); // builds the bone bodies whose capsules the cape captures

    MaterialId cape_material = cloth_material(assets, { 0.12f, 0.2f, 0.55f, 1 })!;
    GeometryId cape_geometry;
    @pool() {
        Geometry cape = cloth_grid(
            allocator: tmem,
            columns:   CAPE_COLUMNS,
            rows:      CAPE_ROWS,
            width:     CAPE_WIDTH,
            height:    CAPE_LENGTH,
        );
        cape_geometry = assets.add_geometry(&cape, "cloth/cape")!;
    };
    // The grid hangs along -Y with its normal on +Z, so turning +Z backward lays it across the back.
    Quat heading = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::atan2(facing.x, facing.z));
    Vec3 right = heading.rotate_vec3({ -1, 0, 0 });
    Node* chest = joints[skeleton.find_joint(CAPE_JOINT)!];
    maths::Transform placement = {
        .position = maths::translation(chest.world) + (Vec3){ 0, CAPE_SHOULDER_HEIGHT, 0 }
            - facing * CAPE_BACK_OFFSET - right * (CAPE_WIDTH * 0.5f),
        .rotation = heading.mul(quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI)),
        .scale    = { 1, 1, 1 },
    };
    character.cape = scene.add_mesh(
        geometry: cape_geometry,
        material: cape_material,
        parent:   chest,
        name:     "cape",
    )!;
    character.cape.local = maths::transform_from_mat4(maths::inverse_affine(chest.world).mul(placement.to_mat4()));
    scene.get(character.cape, scene::Mesh).trace = demo.traced;
    scene.add(character.cape, grid_wind(
        columns: CAPE_COLUMNS,
        rows:    CAPE_ROWS,
        width:   CAPE_WIDTH,
        height:  CAPE_LENGTH,
    ));
    scene.update_world();
}

fn void? attach_flag(Demo* demo) @local {
    ClothDesc desc = cloth::default_cloth_desc();
    @pool() {
        uint[] pins = alloc::new_array(tmem, uint, (sz)(demo.flag_rows + 1));
        foreach (row, &pin : pins) *pin = (uint)row * (demo.flag_columns + 1);
        desc.pins = pins;
        demo.scene.add_cloth(&demo.assets, demo.flag, desc)!;
    };
}

fn void? attach_cape(Demo* demo) @local {
    Ragdoll* ragdoll = demo.scene.get(demo.character.skin, Ragdoll);
    ClothDesc desc = cloth::default_cloth_desc();
    desc.collide_ground = true;
    desc.thickness = CAPE_THICKNESS;
    desc.tangent_frame = true;
    desc.bend_mode = DIHEDRAL;
    desc.bend_compliance = 2.0f;
    Entity[ragdoll_bones::RIGIFY_BONE_COUNT] colliders;
    foreach (index, bone : ragdoll.bone_nodes) colliders[index] = bone.id;
    desc.colliders = colliders[..];
    @pool() {
        ClothAttachment[] attachments = alloc::new_array(tmem, ClothAttachment, (sz)(CAPE_COLUMNS + 1));
        foreach (column, &attachment : attachments) {
            bool outer = column == 0 || column == CAPE_COLUMNS;
            *attachment = {
                .particle   = (uint)column,
                .weight     = 1.0f,
                .compliance = outer ? 0.001f : 0.0f,
            };
        }
        desc.attachments = attachments;
        demo.scene.add_cloth(&demo.assets, demo.character.cape, desc)!;
    };
}

fn void? attach_cloths(Demo* demo) @local {
    if (!demo.simulated) return;
    if (demo.flag) attach_flag(demo)!;
    if (demo.character.cape) attach_cape(demo)!;
    if (demo.scenario == CONTACTS) attach_contact_cloths(demo)!;
    if (demo.fold) attach_fold(demo)!;
    if (demo.fast) attach_fast(demo)!;
}

fn void? reset_cloths(Demo* demo) @local {
    if (!demo.simulated) return;
    if (demo.flag) demo.scene.remove_cloth(demo.flag);
    if (demo.character.cape) demo.scene.remove_cloth(demo.character.cape);
    if (demo.fold) demo.scene.remove_cloth(demo.fold);
    if (demo.fast) demo.scene.remove_cloth(demo.fast);
    foreach (node : demo.drapes) if (node) demo.scene.remove_cloth(node);
    return attach_cloths(demo);
}

fn Geometry contact_surface(Allocator allocator, bool prism) @local {
    Geometry geometry;
    if (prism) {
        geometry.positions = alloc::new_array(allocator, Vec3, 6);
        geometry.indices = alloc::new_array(allocator, uint, 24);
        geometry.positions[..] = ((Vec3[6]){
            { -0.5f, 0, -0.6f }, { 0.5f, 0, -0.6f }, { -0.5f, 0.5f, -0.6f },
            { -0.5f, 0, 0.6f }, { 0.5f, 0, 0.6f }, { -0.5f, 0.5f, 0.6f },
        })[..];
        geometry.indices[..] = { 0, 2, 1, 3, 4, 5, 0, 1, 4, 0, 4, 3, 0, 3, 5, 0, 5, 2, 1, 2, 5, 1, 5, 4 }[..];
    } else {
        geometry.positions = alloc::new_array(allocator, Vec3, 4);
        geometry.indices = alloc::new_array(allocator, uint, 6);
        geometry.positions[..] = ((Vec3[4]){
            { -1.5f, -0.375f, -1.5f }, { 1.5f, 0.375f, -1.5f },
            { -1.5f, -0.375f, 1.5f }, { 1.5f, 0.375f, 1.5f },
        })[..];
        geometry.indices[..] = { 0, 2, 1, 1, 2, 3 }[..];
    }
    geometry.compute_normals(allocator);
    geometry.finalize();
    return geometry;
}

fn Geometry contact_field(Allocator allocator) @local {
    Geometry geometry = {
        .positions = alloc::new_array(allocator, Vec3, 16),
        .indices = alloc::new_array(allocator, uint, 48),
    };
    for (uint row = 0; row < 4; row++) {
        for (uint column = 0; column < 4; column++) geometry.positions[4 * row + column] = { (float)column, (float)column, (float)row };
    }
    usz index;
    for (uint row = 0; row < 3; row++) {
        for (uint column = 0; column < 3; column++) {
            if (row == 1 && column == 1) continue;
            uint first = 4 * row + column;
            geometry.indices[index:6] = ((uint[6]){ first, first + 4, first + 1, first + 1, first + 4, first + 5 })[..];
            index += 6;
        }
    }
    geometry.compute_normals(allocator);
    geometry.finalize();
    return geometry;
}

fn void? contact_visual(
    Demo* demo,
    Node* body,
    GeometryId geometry,
    MaterialId material,
    maths::Transform local,
) @local {
    Node* visual = demo.scene.add_mesh(geometry: geometry, material: material, parent: body, name: "collider")!;
    visual.local = local;
    demo.scene.get(visual, scene::Mesh).trace = demo.traced;
}

fn void? build_contact_scene(Demo* demo) @local {
    @pool() {
        MaterialId obstacle = demo.assets.add_material(material::standard({ .base_color = { 0.23f, 0.26f, 0.3f, 1 }, .roughness = 0.7f }))!;
        Geometry cube = geometry::box(allocator: tmem, width: 1, height: 1, depth: 1);
        Geometry prism = contact_surface(tmem, true);
        Geometry ramp = contact_surface(tmem, false);
        Geometry field = contact_field(tmem);
        GeometryId cube_id = demo.assets.add_geometry(&cube)!;
        GeometryId prism_id = demo.assets.add_geometry(&prism)!;
        GeometryId ramp_id = demo.assets.add_geometry(&ramp)!;
        GeometryId field_id = demo.assets.add_geometry(&field)!;

        Vec3[5] positions = { { -12, 0, 0 }, { -6, 0, 0 }, { 0, 0, 0 }, { 6, 0, 0 }, { 14, 0, 0 } };
        ColliderDesc[5] colliders;
        colliders[0] = physics::default_collider_desc(BOX);
        colliders[0].half_extents = { 0.75f, 0.5f, 0.6f };
        colliders[0].local.position = { 0.2f, 0.3f, 0 };
        colliders[0].local.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 2);

        colliders[1] = physics::default_collider_desc(HULL);
        colliders[1].geometry = prism_id;
        colliders[1].local.position = { 0.25f, 0.25f, 0 };
        colliders[1].local.scale = { 1, 2, 1 };

        colliders[2] = physics::default_collider_desc(MESH);
        colliders[2].geometry = ramp_id;
        colliders[2].local.scale = { 1, 2, 1 };

        float[16] heights;
        foreach (index, &height : heights) *height = (float)(index % 4);
        char[9] materials;
        materials[4] = physics::HEIGHT_FIELD_HOLE;
        SurfaceMaterialDesc surface = physics::default_surface_material();
        colliders[3] = physics::default_collider_desc(HEIGHT_FIELD);
        colliders[3].height_field = { .heights = heights[..], .count_x = 4, .count_z = 4 };
        colliders[3].local.scale = { 1, 0.25f, 1 };
        colliders[3].material_indices = materials[..];
        colliders[3].face_materials = (&surface)[:1];

        CompoundChild[2] children;
        children[0] = physics::default_compound_child(BOX);
        children[0].half_extents = { 0.35f, 0.15f, 0.4f };
        children[0].local.position = { -1, 0.4f, 0 };
        children[0].local.rotation = quaternion::from_axis_angle{float}({ 0, 0, 1 }, (float)math::PI / 2);
        children[1] = physics::default_compound_child(MESH);
        children[1].geometry = ramp_id;
        children[1].local.position = { 1, 0.5f, 0 };
        children[1].local.rotation = quaternion::from_axis_angle{float}({ 0, 1, 0 }, (float)math::PI / 2);
        children[1].local.scale = { 0.5f, 2, 1 };
        colliders[4] = physics::default_collider_desc(COMPOUND);
        colliders[4].children = children[..];

        GeometryId[4] geometry_ids = { cube_id, prism_id, ramp_id, field_id };
        foreach (index, &collider : colliders) {
            Node* body = demo.scene.add_node(name: "contact body")!;
            body.local.position = positions[index];
            if (index < 4) {
                maths::Transform local = collider.local;
                if (index == 0) local.scale = collider.half_extents * 2;
                contact_visual(demo: demo, body: body, geometry: geometry_ids[index], material: obstacle, local: local)!;
            } else {
                foreach (child_index, &child : children) {
                    maths::Transform local = child.local;
                    if (!child_index) local.scale = child.half_extents * 2;
                    contact_visual(demo: demo, body: body, geometry: child_index ? ramp_id : cube_id, material: obstacle, local: local)!;
                }
            }
            demo.scene.update_world();
            demo.physics.add_body(body, physics::default_body_desc(STATIC), collider[:1])!;
            demo.drape_bodies[index] = body.id;
        }
        demo.drape_bodies[5] = demo.drape_bodies[4];

        float[5][6] bounds = {
            { -12.45f, -11.15f, -0.4f, 0.4f, 1.2f }, { -6.15f, -5.35f, -0.4f, 0.4f, 1.25f },
            { -0.6f, 0.6f, -0.4f, 0.4f, 0.45f }, { 6.15f, 6.85f, 0.15f, 0.85f, 0.35f },
            { 12.75f, 13.25f, -0.3f, 0.3f, 0.9f }, { 14.65f, 15.35f, -0.3f, 0.3f, 1.0f },
        };
        foreach (section, range : bounds) {
            Geometry sheet = geometry::plane(allocator: tmem, width: 1, depth: 1, segments_x: 4, segments_z: 4);
            for (uint row = 0; row < 5; row++) {
                for (uint column = 0; column < 5; column++) {
                    sheet.positions[5 * row + column] = {
                        range[0] + (range[1] - range[0]) * (float)row / 4,
                        range[4], range[2] + (range[3] - range[2]) * (float)column / 4,
                    };
                }
            }
            for (usz corner = 0; corner < sheet.indices.len; corner += 3) {
                uint second = sheet.indices[corner + 1];
                sheet.indices[corner + 1] = sheet.indices[corner + 2];
                sheet.indices[corner + 2] = second;
            }
            sheet.compute_normals(tmem);
            sheet.finalize();
            MaterialId fabric = cloth_material(&demo.assets, section % 2 ? (Vec4){ 0.82f, 0.36f, 0.13f, 1 } : (Vec4){ 0.12f, 0.5f, 0.7f, 1 })!;
            demo.drapes[section] = demo.scene.add_mesh(demo.assets.add_geometry(&sheet)!, fabric, name: "drape")!;
            demo.scene.get(demo.drapes[section], scene::Mesh).trace = demo.traced;
        }
    };
}

fn void? attach_contact_cloths(Demo* demo) @local {
    uint[5] pins = { 0, 1, 2, 3, 4 };
    foreach (index, node : demo.drapes) {
        if (!node) continue;
        ClothDesc desc = cloth::default_cloth_desc();
        desc.pins = pins[..];
        desc.colliders = (&demo.drape_bodies[index])[:1];
        demo.scene.add_cloth(&demo.assets, node, desc)!;
    }
}

fn void? build_fold(Demo* demo) @local {
    Vec3[14] positions = {
        { -1, 0, -1 }, { 1, 0, -1 },
        { -1, 0, 1 }, { 1, 0, 1 },
        { -1, 0, 3 }, { 1, 0, 3 },
        { -1, 1, 4 }, { 1, 1, 4 },
        { -0.6f, 0.005f, 1.2f }, { 1.4f, 0.005f, 1.2f },
        { -0.6f, 0.005f, -0.8f }, { 1.4f, 0.005f, -0.8f },
        { -1, 0, 3 }, { 1, 0, 3 },
    };
    uint[30] indices;
    for (uint row = 0; row < 5; row++) {
        uint first = 2 * row;
        indices[6 * row:6] = ((uint[6]){ first, first + 2, first + 1, first + 1, first + 2, first + 3 })[..];
    }
    for (uint index = 12; index < indices.len; index++) {
        if (indices[index] == 4) indices[index] = 12;
        if (indices[index] == 5) indices[index] = 13;
    }
    @pool() {
        Geometry geometry = { .positions = positions[..], .indices = indices[..] };
        geometry.compute_normals(tmem);
        geometry.finalize();
        MaterialId fabric = cloth_material(&demo.assets, { 0.88f, 0.35f, 0.1f, 1 })!;
        demo.fold = demo.scene.add_mesh(demo.assets.add_geometry(&geometry)!, fabric, name: "folded seamed strip")!;
        demo.scene.get(demo.fold, scene::Mesh).trace = demo.traced;
    };
}

fn void? attach_fold(Demo* demo) @local {
    uint[6] pins = { 4, 5, 6, 7, 12, 13 };
    ClothSeam[2] seams = { { .first = 4, .second = 12 }, { .first = 5, .second = 13 } };
    ClothDesc desc = cloth::default_cloth_desc();
    desc.pins = pins[..];
    desc.seams = seams[..];
    desc.gravity_scale = 0;
    desc.damping = 3;
    desc.collisions.self_collision = true;
    demo.scene.add_cloth(&demo.assets, demo.fold, desc)!;
}

fn void? build_fast(Demo* demo) @local {
    const uint COLUMNS = 4;
    const uint ROWS = 2;
    @pool() {
        Geometry patch = cloth_grid(
            allocator: tmem,
            columns: COLUMNS,
            rows: ROWS,
            width: 1.4f,
            height: 0.7f,
        );
        foreach (&position : patch.positions) *position = { 0.4f + position.x, 0, position.y + 0.35f };
        patch.compute_normals(tmem);
        patch.finalize();
        MaterialId fabric = cloth_material(&demo.assets, { 0.95f, 0.32f, 0.06f, 1 })!;
        demo.fast = demo.scene.add_mesh(demo.assets.add_geometry(&patch)!, fabric, name: "continuous cloth")!;
        demo.scene.get(demo.fast, scene::Mesh).trace = demo.traced;
        Geometry bar = geometry::box(
            allocator: tmem,
            width: 4,
            height: 0.1f,
            depth: 1.2f,
        );
        MaterialId metal = demo.assets.add_material(
            material: material::standard(
                params: { .base_color = { 0.14f, 0.28f, 0.44f, 1 }, .roughness = 0.4f, .metallic = 0.3f },
            ),
        )!;
        demo.fast_body = demo.scene.add_mesh(demo.assets.add_geometry(&bar)!, metal, name: "sweeping thin box")!;
        demo.fast_body.local.rotation = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, -(float)math::PI / 4);
        demo.scene.update_world();
        ColliderDesc collider = physics::default_collider_desc(BOX);
        collider.half_extents = { 2, 0.05f, 0.6f };
        demo.physics.add_body(demo.fast_body, physics::default_body_desc(STATIC), (&collider)[:1])!;
    };
}

fn void? attach_fast(Demo* demo) @local {
    demo.physics.teleport(
        node: demo.fast_body,
        position: {},
        rotation: quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, -(float)math::PI / 4),
    );
    demo.scene.update_world();
    demo.fast_frame = demo.fast_impacts = 0;
    ClothDesc desc = cloth::default_cloth_desc();
    desc.substeps = desc.iterations = 1;
    desc.stretch_stiffness = desc.bend_stiffness = desc.gravity_scale = 0;
    desc.damping = 1 / physics::DEFAULT_FIXED_DT;
    desc.colliders = (&demo.fast_body.id)[:1];
    desc.collisions.self_collision = true;
    desc.collisions.continuous = true;
    demo.scene.add_cloth(&demo.assets, demo.fast, desc)!;
}

fn void? create_demo(
    Demo* demo,
    Scenario scenario,
    uint flag_columns,
    uint flag_rows,
    bool simulated,
    bool traced = false,
) @local {
    demo.scenario = scenario;
    demo.simulated = simulated;
    demo.traced = traced;
    demo.flag_columns = flag_columns;
    demo.flag_rows = flag_rows;
    demo.assets = asset::create_asset_store(mem, asset::default_asset_store_desc());
    defer catch asset::destroy_asset_store(&demo.assets);
    demo.scene = scene::create_scene(mem, { .max_nodes = SCENE_NODE_CAPACITY });
    defer catch scene::destroy_scene(&demo.scene);
    physics::register_physics(&demo.scene)!;
    demo.physics = physics::create_physics_world(
        allocator: mem,
        assets:    &demo.assets,
        scene:     &demo.scene,
        desc:      physics::default_physics_desc(),
    )!;
    defer catch physics::destroy_physics_world(&demo.physics);

    MaterialId ground_material = demo.assets.add_material(material::standard({
        .base_color = { 0.22f, 0.27f, 0.2f, 1 }, .roughness = 0.95f,
    }))!;
    GeometryId ground_geometry;
    @pool() {
        Geometry ground = geometry::plane(tmem, 40, 40);
        ground_geometry = demo.assets.add_geometry(&ground, "cloth/ground")!;
    };
    Node* ground = demo.scene.add_mesh(ground_geometry, ground_material, name: "ground")!;
    if (scenario == CONTACTS || scenario == FOLD || scenario == FAST) ground.local.position.y = -1.2f;
    if (scenario == FAST) ground.local.position.y = -1.8f;
    Light sun_light = light::directional({ 1, 0.96f, 0.9f }, 3);
    sun_light.shadow.ray_traced = traced;
    Node* sun = demo.scene.add_light(sun_light, name: "sun")!;
    sun.local.rotation = maths::look_rotation(((Vec3){ -0.4f, -1, -0.6f }).normalize(), { 0, 1, 0 });
    demo.scene.ambient_color = { 0.55f, 0.65f, 0.8f };
    demo.scene.ambient_intensity = 0.35f;
    demo.scene.background = { .kind = COLOR, .color = { 0.45f, 0.6f, 0.8f, 1 } };
    demo.camera = demo.scene.add_camera(camera::perspective_deg(45, 0.05f), name: "camera")!;
    demo.scene.update_world();
    ColliderDesc ground_collider = physics::default_collider_desc(MESH);
    ground_collider.geometry = ground_geometry;
    demo.physics.add_body(ground, physics::default_body_desc(STATIC), (&ground_collider)[:1])!;

    if (scenario == FLAG || scenario == BOTH) build_flag(demo)!;
    if (scenario == CAPE || scenario == BOTH) build_character(demo)!;
    if (scenario == CONTACTS) build_contact_scene(demo)!;
    if (scenario == FOLD) build_fold(demo)!;
    if (scenario == FAST) build_fast(demo)!;
    switch (scenario) {
        case FLAG:
            demo.camera.local.position = POLE_POSITION + (Vec3){ 1.4f, POLE_HEIGHT - 0.6f, 4.2f };
            demo.camera.local.rotation = maths::look_rotation(((Vec3){ -0.25f, 0, -1 }).normalize(), { 0, 1, 0 });
        case CAPE:
            demo.camera.local.position = CHARACTER_POSITION + (Vec3){ 0.6f, 1.5f, 2.6f };
            demo.camera.local.rotation = maths::look_rotation(((Vec3){ -0.2f, -0.18f, -1 }).normalize(), { 0, 1, 0 });
        case CONTACTS:
            demo.camera.local.position = { 2, 12, 22 };
            demo.camera.local.rotation = maths::look_rotation(((Vec3){ 0, -11, -22 }).normalize(), { 0, 1, 0 });
        case FOLD:
            demo.camera.local.position = { 5, 2.6f, -5 };
            demo.camera.local.rotation = maths::look_rotation(((Vec3){ -5, -2.2f, 6.5f }).normalize(), { 0, 1, 0 });
        case FAST:
            demo.camera.local.position = { -1.975f, 4.275f, 5 };
            demo.camera.local.rotation = maths::look_rotation(((Vec3){ 2.375f, -3.875f, -5 }).normalize(), { 0, 1, 0 });
        case BOTH:
            demo.camera.local.position = { 0.2f, 2.3f, 6.8f };
            demo.camera.local.rotation = maths::look_rotation(((Vec3){ 0, -0.05f, -1 }).normalize(), { 0, 1, 0 });
    }
    demo.scene.update_world();
    attach_cloths(demo)!;
    demo.wind_speed = DEFAULT_WIND_SPEED;
    demo.wind_heading = DEFAULT_WIND_HEADING;
    demo.gusts = true;
}

fn void destroy_demo(Demo* demo) @local {
    physics::destroy_physics_world(&demo.physics);
    scene::destroy_scene(&demo.scene);
    asset::destroy_asset_store(&demo.assets);
}

fn void apply_wind(Demo* demo, double time) @local {
    float speed = demo.wind_speed;
    if (demo.gusts) speed *= 1 + GUST_SHARE * math::sin((float)time * GUST_RATE) * math::sin((float)time * GUST_RATE * 2.3f);
    float heading = math::deg_to_rad(demo.wind_heading);
    Vec3 velocity = { math::cos(heading) * speed, 0, math::sin(heading) * speed };
    if (demo.flag) demo.scene.get(demo.flag, Wind).velocity = velocity;
    if (demo.character.cape) demo.scene.get(demo.character.cape, Wind).velocity = velocity;
}

fn void set_ragdoll(Demo* demo, bool enabled) @local {
    Character* character = &demo.character;
    if (enabled) {
        demo.physics.set_ragdoll_mode(character.skin, SIMULATED);
        demo.scene.get(character.skin, Ragdoll).weight = 1;
    } else {
        if (catch excuse = demo.physics.recover_bones(character.skin)) {
            io::printfn("Cannot recover ragdoll: %s", excuse);
            return;
        }
    }
    character.ragdoll = enabled;
}

fn uint cloth_revision(Demo* demo, Node* node) @local {
    if (!node || !demo.simulated) return 0;
    return demo.assets.geometry(demo.scene.get(node, scene::Mesh).geometry).header.revision;
}

// Comparison mode: a whole mark makes the renderer upload every stream of the geometry.
fn void publish_whole(Demo* demo, Node* node, uint revision_before) @local {
    if (!node || !demo.simulated) return;
    GeometryId geometry = demo.scene.get(node, scene::Mesh).geometry;
    if (demo.assets.geometry(geometry).header.revision != revision_before) demo.assets.mark_geometry_dirty(geometry);
}

// Animation, physics and final ragdoll poses precede the cloth, so pins and contacts see this frame's pose.
fn void step_demo(Demo* demo, float delta, double time) @local {
    apply_wind(demo, time);
    if (demo.character.root && !demo.character.ragdoll) {
        Ragdoll* ragdoll = demo.scene.get(demo.character.skin, Ragdoll);
        ragdoll.weight = math::max(ragdoll.weight - delta / BLEND_OUT_SECONDS, 0.0f);
    }
    if (demo.character.root) anim::update(&demo.assets, &demo.scene, delta);
    demo.scene.update_world();
    demo.physics.update(delta);
    if (demo.character.root && !demo.character.ragdoll) {
        Ragdoll* ragdoll = demo.scene.get(demo.character.skin, Ragdoll);
        if (ragdoll.weight == 0 && ragdoll.recovery_status().participating > 0) {
            if (catch excuse = demo.physics.finish_ragdoll_recovery(demo.character.skin)) {
                if (excuse != physics::RECOVERY_NOT_READY) io::printfn("Cannot finish ragdoll recovery: %s", excuse);
            }
        }
    }
    demo.physics.update_ragdolls();
    if (demo.fast && demo.fast_frame == 1) {
        demo.fast_body.local.position = { 0.1f, 0, 0 };
        demo.fast_body.local.rotation = quaternion::from_axis_angle((Vec3){ 0, 0, 1 }, (float)math::PI / 4);
    }
    demo.scene.update_world();

    uint flag_revision = cloth_revision(demo, demo.flag);
    uint cape_revision = cloth_revision(demo, demo.character.cape);
    uint fold_revision = cloth_revision(demo, demo.fold);
    uint fast_revision = cloth_revision(demo, demo.fast);
    uint[6] drape_revisions;
    foreach (index, node : demo.drapes) drape_revisions[index] = cloth_revision(demo, node);
    demo.physics.update_cloths();
    if (demo.fast) {
        demo.fast_frame++;
        demo.fast_impacts += demo.physics.cloth_stats.impacts;
    }
    if (demo.whole_publication) {
        publish_whole(demo, demo.flag, flag_revision);
        publish_whole(demo, demo.character.cape, cape_revision);
        publish_whole(demo, demo.fold, fold_revision);
        publish_whole(demo, demo.fast, fast_revision);
        foreach (index, node : demo.drapes) publish_whole(demo, node, drape_revisions[index]);
    }
}

fn void? configure_temporal(Renderer* renderer, ViewId view, Controls controls) @local {
    ViewDesc desc = renderer.views.get(view).desc;
    desc.post.anti_aliasing = controls.taa ? AntiAliasing.TAA : AntiAliasing.NONE;
    desc.post.motion_blur = controls.motion_blur;
    return render::configure_view(renderer, view, desc);
}

fn void panel(
    Demo* demo,
    Controls* controls,
    Renderer* renderer,
    float frame_ms,
) @local {
    if (imgui::begin("Cloth", null, {})) {
        ClothStats stats = demo.physics.cloth_stats;
        uint upload_bytes = renderer.stats.upload_bytes;
        uint history_bytes = renderer.stats.vertex_history_bytes;
        imgui::text("Scene: %s", SCENARIO_NAMES[demo.scenario.ordinal]);
        imgui::text("Solve %.3f ms, publish %.3f ms", stats.solve_seconds * 1000, stats.publish_seconds * 1000);
        imgui::text("Particles %u, constraints %u", stats.particles, stats.constraints);
        imgui::text("Contacts: %u candidates, %u contacts", stats.candidates, stats.contacts);
        if (demo.fold) imgui::text("Self contact enabled, 2 copied seam pairs, gap 0.02 m");
        if (demo.fast) {
            imgui::text("Continuous and self contact enabled; %u swept impacts", demo.fast_impacts);
            imgui::text("One 90-degree sweep in a fixed step; reset to repeat");
        }
        imgui::text("Failures %u, residual %.6f m", stats.failed, stats.max_residual);
        imgui::text("Geometry upload %u bytes, history %u bytes", upload_bytes, history_bytes);
        imgui::checkbox("Whole geometry upload (U)", &demo.whole_publication);
        imgui::text("Frame %.2f ms", frame_ms);
        imgui::begin_disabled(demo.scenario == CONTACTS || demo.scenario == FOLD || demo.scenario == FAST);
        imgui::slider_float(
            label: "Wind speed",
            v: &demo.wind_speed,
            v_min: 0,
            v_max: 20,
        );
        imgui::slider_float(
            label: "Wind heading",
            v: &demo.wind_heading,
            v_min: -180,
            v_max: 180,
        );
        imgui::checkbox("Gusts", &demo.gusts);
        imgui::end_disabled();
        if (demo.character.root) imgui::checkbox("Ragdoll", &controls.ragdoll);
        imgui::checkbox("Collider guides", &controls.colliders);
        imgui::checkbox("TAA", &controls.taa);
        imgui::checkbox("Motion blur", &controls.motion_blur);
        controls.reset = imgui::button("Reset cloth");
    }
    imgui::end();
}

fn void? run_interactive(Options options) @local {
    platform::Window window = platform::create_window(platform::default_window_desc("c3d cloth", WIDTH, HEIGHT))!;
    defer platform::destroy_window(&window);
    Demo demo;
    create_demo(
        demo:         &demo,
        scenario:     options.scenario,
        flag_columns: FLAG_COLUMNS,
        flag_rows:    FLAG_ROWS,
        simulated:    !options.still,
    )!;
    defer destroy_demo(&demo);
    demo.whole_publication = options.whole_publication;
    Renderer renderer = platform::create_window_renderer(
        allocator: mem,
        window: &window,
        assets: &demo.assets,
        desc: { .validation = true, .gpu_timings = true },
    )!;
    defer render::destroy_renderer(&renderer);
    GuiRenderer gui_renderer = gui::create_gui_renderer(mem, &renderer, &window)!;
    defer (void)gui::destroy_gui_renderer(&gui_renderer);
    debug::DebugDraw guides = debug::create_debug_draw(mem);
    defer debug::destroy_debug_draw(&guides);
    Controls controls = { .taa = true, .motion_blur = true };
    Controls applied;
    double elapsed;
    float frame_ms;
    uint frame;
    while (window.poll()) {
        if (options.frames && frame++ >= options.frames) break;
        if (window.input.key_released(platform::Scancode.ESCAPE) && !window.input.keyboard_captured_by_gui) break;
        if (window.input.key_pressed(platform::Scancode.U) && !window.input.keyboard_captured_by_gui) {
            demo.whole_publication = !demo.whole_publication;
        }
        time::Clock started = clock::now();
        @pool() {
            gui_renderer.new_frame();
            defer if (gui_renderer.frame_open) gui_renderer.finish_frame();
            panel(
                demo:     &demo,
                controls: &controls,
                renderer: &renderer,
                frame_ms: frame_ms,
            );
            gui_renderer.finish_frame();
            platform::sync_window(&window, &renderer);
            if (controls.taa != applied.taa || controls.motion_blur != applied.motion_blur || !frame) {
                configure_temporal(&renderer, renderer.default_view, controls)!;
                applied = controls;
            }
            if (controls.ragdoll != demo.character.ragdoll) {
                set_ragdoll(&demo, controls.ragdoll);
                controls.ragdoll = demo.character.ragdoll;
            }
            if (controls.reset) reset_cloths(&demo)!;
            elapsed += window.clock.delta;
            step_demo(&demo, window.clock.delta, elapsed);
            guides.clear();
            if (controls.colliders) demo.physics.debug_draw(&guides, { .colliders = true });
            renderer.begin_frame({
                .time = elapsed,
                .delta = window.clock.delta,
                .reference_position = demo.camera.world_position(),
            })!;
            defer catch render::abort_frame(&renderer);
            if (renderer.has_output) {
                renderer.render_view(
                    scene:       &demo.scene,
                    camera_node: demo.camera,
                    view:        renderer.default_view,
                    debug:       &guides,
                )!;
                renderer.finish_view(renderer.default_view)!;
                OverlayContext overlay = renderer.begin_overlay()!;
                gui_renderer.record(&overlay)!;
                renderer.end_overlay(&overlay)!;
            }
            renderer.end_frame()!;
        };
        frame_ms = (float)((double)(clock::now() - started) / NANOSECONDS_PER_MILLISECOND);
    }
    return renderer.log.check_validation();
}

fn double percentile(double[] samples, double fraction) @local {
    sort::quicksort(samples);
    usz index = (usz)math::min((double)(samples.len - 1), math::floor(fraction * (double)samples.len));
    return samples[index];
}

fn double mean(double[] samples) @local {
    double total;
    foreach (sample : samples) total += sample;
    return total / (double)samples.len;
}

fn void print_trace_report(
    String path,
    Series trace_build_ms,
    Series pose_ms,
    Series acceleration_ms,
    Series trace_gpu_ms,
    usz gpu_samples,
) @local {
    io::printfn("trace,%s", path);
    io::printfn("trace_build_ms,mean,%.4f,max,%.4f", trace_build_ms.total / MEASURED_FRAMES, trace_build_ms.peak);
    if (!gpu_samples) {
        io::printn("trace_gpu_ms,unavailable");
        return;
    }
    double samples = (double)gpu_samples;
    io::printfn("trace_pose_ms,mean,%.4f,max,%.4f", pose_ms.total / samples, pose_ms.peak);
    io::printfn("acceleration_build_ms,mean,%.4f,max,%.4f", acceleration_ms.total / samples, acceleration_ms.peak);
    io::printfn(
        "trace_work_ms,mean,%.4f,max_bound,%.4f",
        trace_build_ms.total / MEASURED_FRAMES + trace_gpu_ms.total / samples,
        trace_build_ms.peak + trace_gpu_ms.peak,
    );
}

fn void? run_benchmark(Options options) @local {
    Demo demo;
    create_demo(
        demo:         &demo,
        scenario:     options.scenario,
        flag_columns: BENCHMARK_CELLS,
        flag_rows:    BENCHMARK_CELLS,
        simulated:    !options.still,
        traced:       options.traced,
    )!;
    defer destroy_demo(&demo);
    demo.gusts = false;
    demo.whole_publication = options.whole_publication;
    bool hardware = options.traced && options.trace_kind == TraceKind.HARDWARE;
    Renderer? created = render::create_renderer(
        allocator: mem,
        assets:    &demo.assets,
        desc:      { .validation = options.validation, .gpu_timings = true, .ray_queries = hardware },
    );
    if (catch excuse = created) {
        if (hardware) io::eprintn("Hardware tracing needs ray queries; this adapter or driver does not provide them.");
        return excuse~;
    }
    Renderer renderer = created;
    defer render::destroy_renderer(&renderer);
    if (hardware && !renderer.caps.ray_queries.enabled) {
        io::eprintn("Hardware tracing needs ray queries; this adapter or driver does not provide them.");
        return c3d::UNSUPPORTED~;
    }
    RenderTargetId target = render::create_render_target(
        renderer: &renderer,
        desc: render::render_target_desc(WIDTH, HEIGHT, PixelFormat.RGBA8_SRGB),
    )!;
    ViewDesc view_desc = render::texture_view_desc(target, OutputMode.DISPLAY_LDR);
    view_desc.post.anti_aliasing = AntiAliasing.TAA;
    view_desc.post.motion_blur = true;
    view_desc.ray_tracing.shadows = options.traced;
    ViewId view = render::create_view(&renderer, view_desc)!;
    double[MEASURED_FRAMES] solve_ms;
    double[MEASURED_FRAMES] publish_ms;
    double[MEASURED_FRAMES] gpu_ms;
    usz gpu_samples;
    ulong upload_bytes;
    ulong history_bytes;
    Series trace_build_ms;
    Series blas_builds;
    Series blas_updates;
    Series tlas_builds;
    Series upload_series;
    Series pose_ms;
    Series acceleration_ms;
    Series trace_gpu_ms;
    ulong first_measured = renderer.frame_index + WARMUP_FRAMES;
    ulong last_gpu_frame = ulong::max;
    uint total_frames = WARMUP_FRAMES + MEASURED_FRAMES + render::FRAMES_IN_FLIGHT + 1;
    for (uint frame = 0; frame < total_frames; frame++) {
        double time = (double)frame * STEP_SECONDS;
        if (options.ragdoll && frame == WARMUP_FRAMES) set_ragdoll(&demo, true);
        step_demo(&demo, STEP_SECONDS, time);
        if ((demo.scenario == CONTACTS || demo.scenario == FAST) && demo.physics.cloth_stats.failed) return cloth::CONTACT_UNRESOLVED~;
        renderer.begin_frame({ .time = time, .delta = STEP_SECONDS })!;
        defer catch render::abort_frame(&renderer);
        renderer.render_view(&demo.scene, demo.camera, view)!;
        renderer.finish_view(view)!;
        renderer.end_frame()!;
        if (frame >= WARMUP_FRAMES && frame < WARMUP_FRAMES + MEASURED_FRAMES) {
            solve_ms[frame - WARMUP_FRAMES] = demo.physics.cloth_stats.solve_seconds * 1000;
            publish_ms[frame - WARMUP_FRAMES] = demo.physics.cloth_stats.publish_seconds * 1000;
            upload_bytes += renderer.stats.upload_bytes;
            history_bytes += renderer.stats.vertex_history_bytes;
            trace_build_ms.add(renderer.stats.trace_build_ms);
            blas_builds.add(renderer.stats.blas_builds);
            blas_updates.add(renderer.stats.blas_updates);
            tlas_builds.add(renderer.stats.tlas_builds);
            upload_series.add(renderer.stats.upload_bytes);
        }
        Stats* stats = &renderer.stats;
        if (stats.gpu_timing_state == GpuTimingState.READY && stats.gpu_frame_index != last_gpu_frame
            && stats.gpu_frame_index >= first_measured && stats.gpu_frame_index < first_measured + MEASURED_FRAMES) {
            double total;
            foreach (pass_ms : stats.gpu_pass_ms) total += pass_ms;
            gpu_ms[gpu_samples++] = total;
            float pose = stats.gpu_pass_ms[Pass.TRACE_POSE.ordinal];
            float acceleration = stats.gpu_pass_ms[Pass.ACCELERATION_BUILD.ordinal];
            pose_ms.add(pose);
            acceleration_ms.add(acceleration);
            trace_gpu_ms.add((double)(pose + acceleration));
            last_gpu_frame = stats.gpu_frame_index;
        }
    }
    if (options.capture_path.len) {
        char[] pixels = alloc::new_array(mem, char, WIDTH * HEIGHT * CAPTURE_CHANNELS);
        defer alloc::free(mem, pixels.ptr);
        renderer.read_render_target(target, pixels)!;
        file::save(options.capture_path, pixels)!;
    }
    ClothStats stats = demo.physics.cloth_stats;
    io::printfn("adapter,%s", renderer.adapter_name);
    io::printfn("scene,%s,simulated,%s", SCENARIO_NAMES[options.scenario.ordinal], demo.simulated);
    io::printfn(
        "contacts,%s,candidates,%d,contacts,%d,failed,%d,residual_m,%.8f",
        demo.fast ? "continuous" : "discrete",
        stats.candidates,
        stats.contacts,
        stats.failed,
        stats.max_residual
    );
    if (demo.fast) io::printfn(
        "continuous_impacts,%d,ccd_iterations_last_update,%d",
        demo.fast_impacts,
        stats.ccd_iterations
    );
    io::printfn("publication,%s", demo.whole_publication ? "whole" : "streams");
    io::printfn("resolution,%dx%d,particles,%d,constraints,%d", WIDTH, HEIGHT, stats.particles, stats.constraints);
    io::printfn(
        "frames,%d,warmup,%d,substeps,%d,iterations,%d",
        MEASURED_FRAMES,
        WARMUP_FRAMES,
        demo.fast ? 1 : cloth::DEFAULT_CLOTH_SUBSTEPS,
        demo.fast ? 1 : cloth::DEFAULT_CLOTH_ITERATIONS
    );
    io::printfn("solve_ms,mean,%.4f,p95,%.4f", mean(solve_ms[..]), percentile(solve_ms[..], PERCENTILE_95));
    io::printfn("publish_ms,mean,%.4f,p95,%.4f", mean(publish_ms[..]), percentile(publish_ms[..], PERCENTILE_95));
    io::printfn("upload_bytes_per_frame,%.0f", (double)upload_bytes / MEASURED_FRAMES);
    io::printfn("vertex_history_bytes_per_frame,%.0f", (double)history_bytes / MEASURED_FRAMES);
    if (gpu_samples) {
        io::printfn("gpu_frame_ms,samples,%d,median,%.4f,p95,%.4f", gpu_samples,
            percentile(gpu_ms[:gpu_samples], 0.5), percentile(gpu_ms[:gpu_samples], PERCENTILE_95));
    }
    if (options.traced) {
        print_trace_report(
            path:            hardware ? "hardware" : "software",
            trace_build_ms:  trace_build_ms,
            pose_ms:         pose_ms,
            acceleration_ms: acceleration_ms,
            trace_gpu_ms:    trace_gpu_ms,
            gpu_samples:     gpu_samples,
        );
        io::printfn("trace_blas_builds,mean,%.4f,max,%.0f", blas_builds.total / MEASURED_FRAMES, blas_builds.peak);
        io::printfn("trace_blas_updates,mean,%.4f,max,%.0f", blas_updates.total / MEASURED_FRAMES, blas_updates.peak);
        io::printfn("trace_tlas_builds,mean,%.4f,max,%.0f", tlas_builds.total / MEASURED_FRAMES, tlas_builds.peak);
        io::printfn("trace_upload_bytes,mean,%.0f,max,%.0f", upload_series.total / MEASURED_FRAMES, upload_series.peak);
    }
    return renderer.log.check_validation();
}

fn Scenario? scenario_named(String name) @local {
    foreach (index, scenario_name : SCENARIO_NAMES) {
        if (scenario_name == name) return Scenario::from_ordinal(index);
    }
    return c3d::INVALID_ARGUMENT~;
}

fn Options? parse_options(String[] args) @local {
    Options options = { .scenario = BOTH };
    for (usz index = 1; index < args.len; index++) {
        if (args[index] == "--benchmark") {
            options.benchmark = true;
        } else if (args[index] == "--still") {
            options.still = true;
        } else if (args[index] == "--publish" && index + 1 < args.len) {
            String mode = args[++index];
            if (mode != "whole" && mode != "streams") return c3d::INVALID_ARGUMENT~;
            options.whole_publication = mode == "whole";
        } else if (args[index] == "--ragdoll") {
            options.ragdoll = true;
        } else if (args[index] == "--validation") {
            options.validation = true;
        } else if (args[index] == "--trace" && index + 1 < args.len) {
            String kind = args[++index];
            if (kind == "software") {
                options.trace_kind = TraceKind.SOFTWARE;
            } else if (kind == "hardware") {
                options.trace_kind = TraceKind.HARDWARE;
            } else {
                return c3d::INVALID_ARGUMENT~;
            }
            options.traced = true;
        } else if (args[index] == "--scene" && index + 1 < args.len) {
            options.scenario = scenario_named(args[++index])!;
        } else if (args[index] == "--frames" && index + 1 < args.len) {
            options.frames = args[++index].to_uint()!;
        } else if (args[index] == "--capture" && index + 1 < args.len) {
            options.capture_path = args[++index];
        } else {
            return c3d::INVALID_ARGUMENT~;
        }
    }
    if ((options.traced || options.validation) && !options.benchmark) return c3d::INVALID_ARGUMENT~;
    if (options.ragdoll && (!options.benchmark || (options.scenario == FLAG || options.scenario == CONTACTS || options.scenario == FOLD || options.scenario == FAST))) return c3d::INVALID_ARGUMENT~;
    return options;
}

fn int main(String[] args) {
    Options? options = parse_options(args);
    if (catch excuse = options) {
        io::eprintn("Use cloth [--scene flag|cape|both|contacts|fold|fast] [--still] [--frames count]");
        io::eprintn("  [--publish whole|streams]");
        io::eprintn("  [--benchmark [--ragdoll] [--capture path.rgba] [--trace software|hardware] [--validation]]");
        io::eprintn("Run timings without --validation; the validation layers inflate them.");
        return 1;
    }
    fault excuse = options.benchmark ? @catch(run_benchmark(options)) : @catch(run_interactive(options));
    if (excuse) {
        io::eprintfn("Cloth example failed: %s", excuse);
        return 1;
    }
    return 0;
}
