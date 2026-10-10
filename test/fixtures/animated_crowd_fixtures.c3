module c3d::test::animated_crowd_fixtures;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::material;
import c3d::maths;
import c3d::scene;
import std::math;

<* Number of nodes in each authored fixture template. *>
const uint PARTS_NODE_COUNT = 8;
<* Number of meshes in the mixed fixture. *>
const uint PARTS_MESH_COUNT = 5;
<* Number of vertices in each fixture triangle. *>
const uint PARTS_VERTEX_COUNT = 3;
<* Template index of the root joint. *>
const uint PARTS_JOINT_ROOT = 0;
<* Template index of the tip joint. *>
const uint PARTS_JOINT_TIP = 1;
<* Template index of the tip-influenced mesh. *>
const uint PARTS_TIP_SKIN = 2;
<* Template index of the rigid parent. *>
const uint PARTS_RIGID_PARENT = 3;
<* Template index of the animated rigid mesh. *>
const uint PARTS_RIGID_NODE = 4;
<* Template index of the first morph mesh. *>
const uint PARTS_MORPH_A = 5;
<* Template index of the second morph mesh. *>
const uint PARTS_MORPH_B = 6;
<* Template index of the root-influenced mesh. *>
const uint PARTS_ROOT_SKIN = 7;
<* Mesh order shared by fixture geometry and expected vertices. *>
const uint[PARTS_MESH_COUNT] PARTS_MESH_NODES = { 2, 4, 5, 6, 7 };
<* Instance-root placement used by the literal world-space oracle. *>
const Vec3 PARTS_ROOT_POSITION = { 10, 0, -2 };
<* Conservative unplaced box for both authored clips. *>
const Aabb PARTS_POSE_BOUNDS = { .min = { -6, -3, -4 }, .max = { 12, 6, 4 } };

<* Literal world triangles at the authored rest pose. *>
const Vec3[PARTS_MESH_COUNT * PARTS_VERTEX_COUNT] PARTS_REST_POINTS = {
    { 17, 0, -1 }, { 15, 1, -1 }, { 15, 0, -1 },
    { 12, 1, -2 }, { 10, 2, -2 }, { 10, 1, -2 },
    { 11, -0.5f, 0 }, { 10, 0.5f, 0 }, { 10, -0.5f, 0 },
    { 10, 0.5f, 1 }, { 8, 1.5f, 1 }, { 8, 0.5f, 1 },
    { 19, 0, -1 }, { 17, 1, -1 }, { 17, 0, -1 },
};
<* Literal world triangles at the full posing clip endpoint. *>
const Vec3[PARTS_MESH_COUNT * PARTS_VERTEX_COUNT] PARTS_POSED_POINTS = {
    { 18, 0, -1 }, { 16, 1, -1 }, { 16, 0, -1 },
    { 16, 1, -2 }, { 14, 2, -2 }, { 14, 1, -2 },
    { 11, 0.5f, 0 }, { 10, 1.5f, 0 }, { 10, 0.5f, 0 },
    { 10, 0.5f, 1 }, { 8, 1.5f, 1 }, { 8, 0.5f, 1 },
    { 19, 0, -1 }, { 17, 1, -1 }, { 17, 0, -1 },
};
<* Literal triangles after a clip lacking weight channels restores defaults. *>
const Vec3[PARTS_MESH_COUNT * PARTS_VERTEX_COUNT] PARTS_RESTORED_POINTS = {
    { 16.5f, 1, -1 }, { 14.5f, 2, -1 }, { 14.5f, 1, -1 },
    { 14, 2, -2 }, { 12, 3, -2 }, { 12, 2, -2 },
    { 11, -0.5f, 0 }, { 10, 0.5f, 0 }, { 10, -0.5f, 0 },
    { 10, 0.5f, 1 }, { 8, 1.5f, 1 }, { 8, 0.5f, 1 },
    { 19, 0, -1 }, { 17, 1, -1 }, { 17, 0, -1 },
};

<* Model variants sharing deterministic geometry and clips. *>
enum PartsModelVariant {
    MIXED,
    SKIN_FREE,
    COMPATIBLE_ALIAS,
    REORDERED_JOINTS,
    DIFFERENT_BIND,
}

<* Store-owned fixture identities; no independent resource ownership. *>
struct PartsFixture {
    MaterialId material;
    GeometryId[PARTS_MESH_COUNT] geometries;
    SkeletonId common_skin;
    SkeletonId identical_skin;
    SkeletonId different_bind_skin;
    ClipId posing;
    ClipId missing_weights;
    ModelId mixed;
    ModelId skin_free;
    ModelId compatible_alias;
    ModelId reordered_joints;
    ModelId different_bind;
}

<*
 Publish deterministic mixed-model fixture assets.
 @param [&inout] assets : "Owns every published array and borrowed identity."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn PartsFixture? add_parts_fixture(AssetStore* assets) {
    PartsFixture fixture;
    fixture.material = assets.add_material(
        material::basic({ .color = { 1, 1, 1, 1 } }),
        "animated_parts/material",
    )!;
    @pool() {
        Geometry tip = parts_triangle(
            joint: 1,
            skinned: true,
            morphed: false,
            first_x: 1,
        );
        fixture.geometries[0] = assets.add_geometry(&tip, "animated_parts/tip_triangle")!;
        Geometry rigid = parts_triangle(
            joint: 0,
            skinned: false,
            morphed: false,
            first_x: 1,
        );
        fixture.geometries[1] = assets.add_geometry(&rigid, "animated_parts/rigid_triangle")!;
        Geometry morph = parts_triangle(
            joint: 0,
            skinned: false,
            morphed: true,
            first_x: 1,
        );
        fixture.geometries[2] = assets.add_geometry(&morph, "animated_parts/morph_triangle")!;
        fixture.geometries[3] = fixture.geometries[2];
        Geometry root = parts_triangle(
            joint: 0,
            skinned: true,
            morphed: false,
            first_x: 2,
        );
        fixture.geometries[4] = assets.add_geometry(&root, "animated_parts/root_triangle")!;
    };
    fixture.common_skin = add_parts_skin(assets, "animated_parts/common_skin", false)!;
    fixture.identical_skin = add_parts_skin(assets, "animated_parts/identical_skin", false)!;
    fixture.different_bind_skin = add_parts_skin(assets, "animated_parts/different_bind_skin", true)!;
    fixture.posing = add_parts_clip(assets, "animated_parts/posing", false)!;
    fixture.missing_weights = add_parts_clip(assets, "animated_parts/missing_weights", true)!;
    fixture.mixed = add_parts_model(assets, &fixture, PartsModelVariant.MIXED)!;
    fixture.skin_free = add_parts_model(assets, &fixture, PartsModelVariant.SKIN_FREE)!;
    fixture.compatible_alias = add_parts_model(assets, &fixture, PartsModelVariant.COMPATIBLE_ALIAS)!;
    fixture.reordered_joints = add_parts_model(assets, &fixture, PartsModelVariant.REORDERED_JOINTS)!;
    fixture.different_bind = add_parts_model(assets, &fixture, PartsModelVariant.DIFFERENT_BIND)!;
    return fixture;
}

fn Geometry parts_triangle(
    uint joint,
    bool skinned,
    bool morphed,
    float first_x,
) @local {
    Geometry geometry = {
        .topology = Topology.TRIANGLES,
        .positions = alloc::new_array(tmem, Vec3, PARTS_VERTEX_COUNT),
        .normals = alloc::new_array(tmem, Vec3, PARTS_VERTEX_COUNT),
    };
    geometry.positions[0] = { first_x, 0, 0 };
    geometry.positions[1] = { first_x - 1, 1, 0 };
    geometry.positions[2] = { first_x - 1, 0, 0 };
    geometry.normals[..] = (Vec3){ 0, 0, 1 };
    if (skinned) {
        geometry.joints = alloc::new_array(tmem, ushort[<4>], PARTS_VERTEX_COUNT);
        geometry.weights = alloc::new_array(tmem, Vec4, PARTS_VERTEX_COUNT);
        geometry.joints[..] = { (ushort)joint, 0, 0, 0 };
        geometry.weights[..] = (Vec4){ 1, 0, 0, 0 };
    }
    if (morphed) {
        geometry.targets = alloc::new_array(tmem, MorphTarget, 2);
        geometry.targets[0] = {
            .position_deltas = alloc::new_array(tmem, Vec3, PARTS_VERTEX_COUNT),
            .name = "lift_half",
        };
        geometry.targets[1] = {
            .position_deltas = alloc::new_array(tmem, Vec3, PARTS_VERTEX_COUNT),
            .name = "lift_full",
        };
        geometry.targets[0].position_deltas[..] = (Vec3){ 0, 1, 0 };
        geometry.targets[1].position_deltas[..] = (Vec3){ 0, 2, 0 };
        geometry.channels = alloc::new_array(tmem, MorphChannel, 1);
        geometry.channels[0] = {
            .name = "lift",
            .first_target = 0,
            .full_weights = alloc::new_array(tmem, float, 2),
        };
        geometry.channels[0].full_weights[0] = 0.5f;
        geometry.channels[0].full_weights[1] = 1;
    }
    geometry.finalize();
    return geometry;
}

fn Transform parts_transform(Vec3 position, Vec3 scale = { 1, 1, 1 }) @local {
    Transform transform = maths::TRANSFORM_IDENTITY;
    transform.position = position;
    transform.scale = scale;
    return transform;
}

fn SkeletonId? add_parts_skin(AssetStore* assets, String key, bool different_bind) @local {
    Allocator allocator = assets.allocator;
    Skeleton skeleton = {
        .joint_names = alloc::new_array(allocator, String, 2),
        .parents = alloc::new_array(allocator, int, 2),
        .rest_pose = alloc::new_array(allocator, Transform, 2),
        .inverse_bind = alloc::new_array(allocator, Mat4, 2),
    };
    defer catch asset::free_skeleton(allocator, &skeleton);
    skeleton.joint_names[0] = "joint_root".copy(allocator);
    skeleton.joint_names[1] = "joint_tip".copy(allocator);
    skeleton.parents[0] = -1;
    skeleton.parents[1] = 0;
    skeleton.rest_pose[0] = parts_transform({ 2, 0, 0 });
    skeleton.rest_pose[1] = parts_transform({ 0, 3, 0 });
    skeleton.inverse_bind[0] = parts_transform({ 3, 0, 1 }, { 2, 1, 1 }).to_mat4();
    skeleton.inverse_bind[1] = parts_transform({ 3, -3, 1 }, { 2, 1, 1 }).to_mat4();
    if (different_bind) {
        uint bits = bitcast(skeleton.inverse_bind[0].m00, uint);
        skeleton.inverse_bind[0].m00 = bitcast(bits ^ 1u, float);
    }
    return assets.add_skeleton_owned(&skeleton, key);
}

fn Track parts_track(
    Allocator allocator,
    uint target,
    TargetPath path,
    float[] values,
) @local {
    Track track = {
        .target = target,
        .path = path,
        .interpolation = Interpolation.LINEAR,
        .times = alloc::new_array(allocator, float, 2),
        .values = alloc::clone_slice(allocator, values),
    };
    track.times[0] = 0;
    track.times[1] = 1;
    return track;
}

fn ClipId? add_parts_clip(AssetStore* assets, String key, bool missing_weights) @local {
    Allocator allocator = assets.allocator;
    sz count = missing_weights ? 2 : 3;
    AnimationClip clip = {
        .name = key.copy(allocator),
        .duration = 1,
        .tracks = alloc::new_array(allocator, Track, count),
        .targets = alloc::new_array(allocator, uint, count),
    };
    defer catch asset::free_clip(allocator, &clip);
    float[6] tip = missing_weights ? (float[6]){ 0, 3, 0, -0.5f, 4, 0 } : (float[6]){ 0, 3, 0, 1, 3, 0 };
    float[6] rigid = missing_weights ? (float[6]){ 1, 0, 0, 2, 1, 0 } : (float[6]){ 1, 0, 0, 3, 0, 0 };
    clip.targets[0] = PARTS_JOINT_TIP;
    clip.targets[1] = PARTS_RIGID_NODE;
    clip.tracks[0] = parts_track(
        allocator: allocator,
        target: 0,
        path: TargetPath.TRANSLATION,
        values: tip[..],
    );
    clip.tracks[1] = parts_track(
        allocator: allocator,
        target: 1,
        path: TargetPath.TRANSLATION,
        values: rigid[..],
    );
    if (!missing_weights) {
        float[2] weights = { 0.25f, 0.75f };
        clip.targets[2] = PARTS_MORPH_A;
        clip.tracks[2] = parts_track(
            allocator: allocator,
            target: 2,
            path: TargetPath.MORPH_WEIGHTS,
            values: weights[..],
        );
    }
    return assets.add_clip_owned(&clip, key);
}

fn NodeTemplate parts_node(
    Allocator allocator,
    String name,
    int parent,
    Transform local,
) @local {
    return {
        .parent = parent,
        .name = name.copy(allocator),
        .local = local,
        .layers = scene::DEFAULT_LAYERS,
        .visible = true,
    };
}

fn ModelId? add_parts_model(
    AssetStore* assets,
    PartsFixture* fixture,
    PartsModelVariant variant,
) @local {
    String key;
    bool skin_free;
    bool reordered;
    SkeletonId second_skin = fixture.common_skin;
    switch (variant) {
        case MIXED: key = "animated_parts/mixed";
        case SKIN_FREE: key = "animated_parts/skin_free"; skin_free = true;
        case COMPATIBLE_ALIAS: key = "animated_parts/compatible_alias"; second_skin = fixture.identical_skin;
        case REORDERED_JOINTS: key = "animated_parts/reordered_joints"; reordered = true;
        case DIFFERENT_BIND: key = "animated_parts/different_bind"; second_skin = fixture.different_bind_skin;
    }
    Allocator allocator = assets.allocator;
    ModelTemplate template = {
        .nodes = alloc::new_array(allocator, NodeTemplate, PARTS_NODE_COUNT),
        .meshes = alloc::new_array(allocator, ModelMesh, skin_free ? 3 : PARTS_MESH_COUNT),
        .skins = alloc::new_array(allocator, ModelSkin, skin_free ? 0 : 2),
        .clips = alloc::new_array(allocator, ClipId, 2),
    };
    defer catch asset::free_model_template(allocator, &template);
    template.nodes[0] = parts_node(
        allocator: allocator,
        name: "joint_root",
        parent: -1,
        local: parts_transform({ 2, 0, 0 }),
    );
    template.nodes[1] = parts_node(
        allocator: allocator,
        name: "joint_tip",
        parent: 0,
        local: parts_transform({ 0, 3, 0 }),
    );
    template.nodes[2] = parts_node(
        allocator: allocator,
        name: "tip_skin",
        parent: -1,
        local: parts_transform({ 5, 0, 1 }, { 2, 1, 1 }),
    );
    template.nodes[3] = parts_node(
        allocator: allocator,
        name: "rigid_parent",
        parent: -1,
        local: parts_transform({ -2, 1, 0 }, { 2, 1, 1 }),
    );
    template.nodes[4] = parts_node(
        allocator: allocator,
        name: "rigid_mesh",
        parent: 3,
        local: parts_transform({ 1, 0, 0 }),
    );
    template.nodes[5] = parts_node(
        allocator: allocator,
        name: "morph_a",
        parent: -1,
        local: parts_transform({ 0, -1, 2 }),
    );
    template.nodes[6] = parts_node(
        allocator: allocator,
        name: "morph_b",
        parent: 3,
        local: parts_transform({ 0, -2, 3 }),
    );
    template.nodes[7] = parts_node(
        allocator: allocator,
        name: "root_skin",
        parent: -1,
        local: parts_transform({ -4, 2, -3 }),
    );
    uint mesh_index;
    foreach (uint part, node : PARTS_MESH_NODES) {
        if (skin_free && (part == 0 || part == 4)) continue;
        ModelMesh* mesh = &template.meshes[mesh_index++];
        *mesh = { .node = node, .geometry = fixture.geometries[part], .material = fixture.material };
        if (part == 2 || part == 3) {
            mesh.default_morph_weights = alloc::new_array(allocator, float, 1);
            mesh.default_morph_weights[0] = part == 2 ? 0.25f : 0.75f;
        }
    }
    if (!skin_free) {
        foreach (index, &skin : template.skins) {
            skin.mesh_node = index == 0 ? PARTS_TIP_SKIN : PARTS_ROOT_SKIN;
            skin.skeleton = index == 0 ? fixture.common_skin : second_skin;
            skin.joint_nodes = alloc::new_array(allocator, uint, 2);
            skin.joint_nodes[0] = reordered && index == 1 ? 1 : 0;
            skin.joint_nodes[1] = reordered && index == 1 ? 0 : 1;
        }
    }
    template.clips[0] = fixture.posing;
    template.clips[1] = fixture.missing_weights;
    return assets.add_model_owned(&template, key);
}
