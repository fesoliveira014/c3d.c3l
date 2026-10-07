module c3d::serial;

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::maths;
import c3d::model;
import c3d::scene;

const ulong CROWD_POSE_LAYOUT @local = 0x7ffc763d1a2c701e;
const ulong CROWD_INSTANCE_LAYOUT @local = 0xfbef1798330b2174;
const ulong CROWD_AUTHORING_LAYOUT @local = 0x38a5d61c5c279cea;

struct CrowdAuthoring @private {
    ModelId model;
    uint capacity;
    Aabb pose_bounds;
    bool trace;
    CrowdInstance[] instances;
}

fn void? register_crowd_codec() @private {
    describe::register_reflected(CrowdPose)!;
    describe::register_reflected(CrowdInstance)!;
    describe::register_reflected(CrowdAuthoring)!;
    register_core_value(CrowdPose, CROWD_POSE_LAYOUT, &defaults_crowd_pose)!;
    register_core_value(CrowdInstance, CROWD_INSTANCE_LAYOUT, &defaults_crowd_instance)!;
    register_core_value(CrowdAuthoring, CROWD_AUTHORING_LAYOUT, &defaults_crowd)!;
    register_described_owner(AnimatedCrowd, CrowdAuthoring, {
        .name = "c3d.AnimatedCrowd", .phase = OWNER,
        .collect = &collect_crowd, .project = &project_crowd, .attach = &attach_crowd,
    })!;
}

fn void defaults_crowd_pose(void* value) @local {
    *(CrowdPose*)value = { .speed = 1, .loop = true };
}

fn void defaults_crowd_instance(void* value) @local {
    *(CrowdInstance*)value = {
        .placement = maths::TRANSFORM_IDENTITY, .pose = { .speed = 1, .loop = true }, .color = { 1, 1, 1, 1 },
    };
}

fn void defaults_crowd(void* value) @local {
    *(CrowdAuthoring*)value = { .capacity = 1 };
}

fn void? project_crowd(void* component, void* value, WriteContext* context) @local {
    AnimatedCrowd* crowd = component;
    CrowdInstance[] instances = alloc::new_array_try(tmem, CrowdInstance, crowd.count)
      ?? c3d::CAPACITY_EXCEEDED~!;
    foreach (index, &instance : instances) {
        *instance = { .placement = crowd.placements[index], .pose = crowd.poses[index], .color = crowd.colors[index] };
        instance.pose.time = crowd.start_times[index];
    }
    *(CrowdAuthoring*)value = {
        .model = crowd.model, .capacity = (uint)crowd.placements.len,
        .pose_bounds = crowd.pose_bounds, .trace = crowd.trace, .instances = instances,
    };
}

fn void? attach_crowd(void* value, ReadContext* context) @local {
    CrowdAuthoring* source = value;
    model::attach_crowd(
        assets: context.assets,
        scene: context.scene,
        node: context.node,
        model: source.model,
        capacity: source.capacity,
        pose_bounds: source.pose_bounds,
        instances: source.instances,
        trace: source.trace,
    )!;
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
    context.scene.@each(AnimatedCrowd; entity, crowd) {
        if (!context.state.projection[entity.index].selected) {
            foreach (part : crowd.parts) {
                if (context.scene.world.is_alive(part.batch)
                    && context.state.projection[part.batch.index].selected) return c3d::INVALID_ARGUMENT~;
            }
        }
    };
}
