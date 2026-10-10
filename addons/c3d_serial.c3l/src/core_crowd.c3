module c3d::serial;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::maths;
import c3d::model;
import c3d::scene;
import std::math;

const ulong CROWD_POSE_LAYOUT @local = 0x7ffc763d1a2c701e;
const ulong CROWD_INSTANCE_LAYOUT @local = 0xfbef1798330b2174;
const ulong CROWD_AUTHORING_LAYOUT @local = 0x38a5d61c5c279cea;
const ulong CROWD_PLAYBACK_LAYOUT @local = 0xd968ade9d5937c0c;
const ulong CROWD_AUTHORING_V2_LAYOUT @local = 0x73da7a68102f5e2b;
const ulong CROWD_ACTION_V2_LAYOUT @local = 0x8360925cddcb7715;
const ulong CROWD_SPACE_V2_LAYOUT @local = 0x4d5777ab1cce4ecc;
const ulong CROWD_PLAYBACK_V2_LAYOUT @local = 0x7320dbe867e06499;
const ulong CROWD_AUTHORING_V3_LAYOUT @local = 0x5b096137b6e8478c;
const ulong BLEND_TRIANGLE_LAYOUT @local = 0x484666f6dc6513d7;

struct CrowdAuthoring @private {
    ModelId model;
    uint capacity;
    Aabb pose_bounds;
    bool trace;
    CrowdInstance[] instances;
}

struct CrowdAuthoringV2 @private {
    ModelId model;
    uint capacity;
    Aabb pose_bounds;
    bool trace;
    CrowdInstance[] instances;
    uint actions_per_instance;
    uint event_capacity;
    CrowdInstanceAuthoringV1[] playback;
}

struct CrowdInstanceAuthoringV1 @private {
    bool configured;
    uint root_node;
    uint base_action;
    ActionAuthoring[] actions;
    SpaceAuthoring[] spaces;
}

struct CrowdAuthoringV3 @private {
    ModelId model;
    uint capacity;
    Aabb pose_bounds;
    bool trace;
    CrowdInstance[] instances;
    uint actions_per_instance;
    uint event_capacity;
    CrowdInstanceAuthoring[] playback;
}

BinaryCompatibility[2] crowd_binary_compatibility @local = {
    { .version = 1, .read = &read_crowd_v1 },
    { .version = 2, .read = &read_crowd_v2 },
};
uint[2] crowd_text_default_versions @local = { 1, 2 };

fn void? register_crowd_codec() @private {
    describe::register_reflected(CrowdPose)!;
    describe::register_reflected(CrowdInstance)!;
    describe::register_reflected(CrowdAuthoring)!;
    describe::register_reflected(CrowdInstanceAuthoringV1)!;
    describe::register_reflected(CrowdAuthoringV2)!;
    describe::register_reflected(CrowdAuthoringV3)!;

    register_core_value(CrowdPose, CROWD_POSE_LAYOUT, &defaults_crowd_pose)!;
    register_core_value(CrowdInstance, CROWD_INSTANCE_LAYOUT, &defaults_crowd_instance)!;
    register_core_value(CrowdAuthoring, CROWD_AUTHORING_LAYOUT, &defaults_crowd_v1)!;
    register_core_value(CrowdInstanceAuthoringV1, CROWD_PLAYBACK_LAYOUT, &defaults_crowd_playback_v1)!;
    register_described_type(
        $Type: CrowdAuthoringV2,
        version: 2,
        layout: CROWD_AUTHORING_V2_LAYOUT,
        defaults: &defaults_crowd_v2,
    )!;
    register_described_type(
        $Type: CrowdAuthoringV3,
        version: 3,
        layout: CROWD_AUTHORING_V3_LAYOUT,
        defaults: &defaults_crowd,
    )!;

    register_described_owner(AnimatedCrowd, CrowdAuthoringV3, {
        .name = "c3d.AnimatedCrowd",
        .phase = OWNER,
        .collect = &collect_crowd,
        .project = &project_crowd,
        .attach = &attach_crowd,
        .binary_compatibility = crowd_binary_compatibility[..],
        .text_default_versions = crowd_text_default_versions[..],
    })!;
}

fn void? register_animation_authoring_values() @private {
    describe::register_reflected(BlendTriangle)!;
    describe::register_reflected(CrowdActionAuthoring)!;
    describe::register_reflected(CrowdSpaceAuthoring)!;
    describe::register_reflected(CrowdInstanceAuthoring)!;

    register_core_value(BlendTriangle, BLEND_TRIANGLE_LAYOUT, &defaults_blend_triangle)!;
    register_described_type(
        $Type: CrowdActionAuthoring,
        version: 2,
        layout: CROWD_ACTION_V2_LAYOUT,
        defaults: &defaults_crowd_action,
    )!;
    register_described_type(
        $Type: CrowdSpaceAuthoring,
        version: 2,
        layout: CROWD_SPACE_V2_LAYOUT,
        defaults: &defaults_crowd_space,
    )!;
    register_described_type(
        $Type: CrowdInstanceAuthoring,
        version: 2,
        layout: CROWD_PLAYBACK_V2_LAYOUT,
        defaults: &defaults_crowd_playback,
    )!;
}

fn void defaults_blend_triangle(void* value) @local {
    *(BlendTriangle*)value = {};
}

fn void defaults_crowd_pose(void* value) @local {
    *(CrowdPose*)value = { .speed = 1, .loop = true };
}

fn void defaults_crowd_instance(void* value) @local {
    *(CrowdInstance*)value = {
        .placement = maths::TRANSFORM_IDENTITY,
        .pose = { .speed = 1, .loop = true },
        .color = { 1, 1, 1, 1 },
    };
}

fn void defaults_crowd_v1(void* value) @local {
    *(CrowdAuthoring*)value = { .capacity = 1 };
}

fn void defaults_crowd_action(void* value) @local {
    *(CrowdActionAuthoring*)value = { .speed = 1, .weight = 1, .loop = true, .playing = true };
}

fn void defaults_crowd_space(void* value) @local {
    *(CrowdSpaceAuthoring*)value = { .speed = 1, .weight = 1, .playing = true };
}

fn void defaults_crowd_playback(void* value) @local {
    *(CrowdInstanceAuthoring*)value = { .root_node = anim::NO_ROOT_NODE, .base_action = uint::max };
}

fn void defaults_crowd_playback_v1(void* value) @local {
    *(CrowdInstanceAuthoringV1*)value = { .root_node = anim::NO_ROOT_NODE, .base_action = uint::max };
}

fn void defaults_crowd_v2(void* value) @local {
    *(CrowdAuthoringV2*)value = {
        .capacity = 1,
        .actions_per_instance = anim::DEFAULT_CROWD_ACTIONS,
        .event_capacity = anim::DEFAULT_CROWD_EVENT_CAPACITY,
    };
}

fn void defaults_crowd(void* value) @local {
    *(CrowdAuthoringV3*)value = {
        .capacity = 1,
        .actions_per_instance = anim::DEFAULT_CROWD_ACTIONS,
        .event_capacity = anim::DEFAULT_CROWD_EVENT_CAPACITY,
    };
}

fn void? project_crowd(void* component, void* value, WriteContext* context) @local {
    AnimatedCrowd* crowd = component;
    CrowdInstance[] instances = alloc::new_array_try(tmem, CrowdInstance, crowd.count)
      ?? c3d::CAPACITY_EXCEEDED~!;
    foreach (index, &instance : instances) {
        *instance = {
            .placement = crowd.placements[index],
            .pose = crowd.seeds[index],
            .color = crowd.colors[index],
        };
        instance.pose.time = crowd.start_times[index];
    }

    check_crowd_scalars(instances)!;

    CrowdInstanceAuthoring[] playback;
    if (crowd.is_prepared()) {
        playback = anim::capture_crowd_authoring(tmem, crowd.playback)!.instances;
    } else if (crowd.authoring) {
        playback = crowd.authoring.instances;
    }

    ModelTemplate* template = &context.assets.models.try_get(crowd.model)!.data;
    foreach (index, source : playback) {
        anim::validate_crowd_authoring(
            assets: context.assets,
            template: template,
            source: source,
            actions_per_instance: crowd.actions_per_instance,
            placement: crowd.placements[index],
            model: crowd.model,
        )!;
    }

    *(CrowdAuthoringV3*)value = {
        .model = crowd.model,
        .capacity = (uint)crowd.placements.len,
        .pose_bounds = crowd.pose_bounds,
        .trace = crowd.trace,
        .instances = instances,
        .actions_per_instance = crowd.actions_per_instance,
        .event_capacity = crowd.event_capacity,
        .playback = playback,
    };
}

fn void? check_crowd_scalars(CrowdInstance[] instances) @local {
    foreach (instance : instances) {
        if (!math::is_finite(instance.pose.speed) || !math::is_finite(instance.pose.time)) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn void? attach_crowd(void* value, ReadContext* context) @local {
    CrowdAuthoringV3* source = value;
    check_crowd_scalars(source.instances)!;

    model::attach_crowd(
        assets: context.assets,
        scene: context.scene,
        node: context.node,
        model: source.model,
        capacity: source.capacity,
        pose_bounds: source.pose_bounds,
        instances: source.instances,
        trace: source.trace,
        actions_per_instance: source.actions_per_instance,
        event_capacity: source.event_capacity,
        authoring: source.playback,
    )!;
}

fn void? read_crowd_v1(Reader* reader, ReadContext* context) @local {
    CrowdAuthoring legacy;
    Acquisitions owned = { .allocator = context.allocator };
    defer owned.release();

    read_described_value(
        type: described_type(CrowdAuthoring)!,
        reader: reader,
        context: context,
        owned: &owned,
        value: &legacy,
    )!;

    CrowdAuthoringV3 source = {
        .model = legacy.model,
        .capacity = legacy.capacity,
        .pose_bounds = legacy.pose_bounds,
        .trace = legacy.trace,
        .instances = legacy.instances,
        .actions_per_instance = anim::DEFAULT_CROWD_ACTIONS,
        .event_capacity = anim::DEFAULT_CROWD_EVENT_CAPACITY,
    };

    attach_crowd(&source, context)!;
}

fn void? read_crowd_v2(Reader* reader, ReadContext* context) @local {
    CrowdAuthoringV2 legacy;
    Acquisitions owned = { .allocator = context.allocator };
    defer owned.release();

    read_described_value(
        type: described_type(CrowdAuthoringV2)!,
        reader: reader,
        context: context,
        owned: &owned,
        value: &legacy,
    )!;

    CrowdAuthoringV3 source = {
        .model = legacy.model,
        .capacity = legacy.capacity,
        .pose_bounds = legacy.pose_bounds,
        .trace = legacy.trace,
        .instances = legacy.instances,
        .actions_per_instance = legacy.actions_per_instance,
        .event_capacity = legacy.event_capacity,
        .playback = alloc::new_array_try(tmem, CrowdInstanceAuthoring, legacy.playback.len)
          ?? c3d::CAPACITY_EXCEEDED~!,
    };

    foreach (index, instance : legacy.playback) {
        AnimatorAuthoringV2 converted = migrate_animation_authoring({
            .root_node = instance.root_node,
            .actions = instance.actions,
            .spaces = instance.spaces,
        })!;
        source.playback[index] = {
            .configured = instance.configured,
            .root_node = instance.root_node,
            .base_action = instance.base_action,
            .actions = converted.actions,
            .spaces = converted.spaces,
        };
    }

    attach_crowd(&source, context)!;
}

fn void? collect_crowd(void* component, WriteContext* context) @local {
    AnimatedCrowd* crowd = component;
    ModelTemplate* template = &context.assets.models.try_get(crowd.model)!.data;
    foreach (part : crowd.parts) {
        if (!context.scene.world.is_alive(part.batch)) return c3d::INVALID_ARGUMENT~;
        Node* node = context.scene.node(part.batch);
        if (node.parent != context.node) return c3d::INVALID_ARGUMENT~;
        InstancedMesh* batch = context.scene.get(node, InstancedMesh);
        if (!batch) return c3d::INVALID_ARGUMENT~;
        bool matches;
        foreach (mesh : template.meshes) {
            if (mesh.node == part.template_node && c3d::same_id(mesh.geometry, batch.geometry)
              && c3d::same_id(mesh.material, batch.material)) matches = true;
        }

        if (!matches) return c3d::INVALID_ARGUMENT~;
        context.omit_component(node, ecs::slot_of(InstancedMesh)!)!;
        context.omit_node(node)!;
    }
}

fn void? validate_crowd_selection(WriteContext* context) @private {
    foreach (node : context.state.ordered[:context.state.count]) {
        Entity owner = context.state.projection[node.id.index].owners.crowd;
        if (owner.generation && !context.state.projection[owner.index].selected) return c3d::INVALID_ARGUMENT~;
    }
}
