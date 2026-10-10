module c3d::scene;

import c3d;
import c3d::anim;
import c3d::ecs;
import c3d::ecs::store;
import c3d::maths;
import std::math;

struct CrowdRemovalContext @private {
    Allocator allocator;
    store::ComponentStore{LodGroup}* lod_groups;
}

<* Captured single-clip seed used when an instance is replaced. *>
struct CrowdPose {
    ClipId clip;
    float time;
    float speed;
    bool loop;
}

<* One logical model mesh drawn by an owned child batch. *>
struct CrowdPart {
    Entity batch;
    uint template_node;
    uint mesh_index;
    bool skinned;
    uint weight_count;
    uint weight_offset;
}

<*
 Scene-owned instances sharing immutable model data and bounded playback.
 Only placement and color elements are directly writable.
*>
struct AnimatedCrowd {
    ModelId model;
    uint count;
    uint joint_count;
    uint morph_stride;
    uint actions_per_instance;
    uint event_capacity;
    Aabb pose_bounds;
    bool trace;
    anim::CrowdPlaybackState* playback;
    anim::CrowdAuthoringState* authoring;
    CrowdPart[] parts;
    Transform[] placements;
    CrowdPose[] seeds;
    float[] start_times;
    Vec4[] colors;
    Mat4[] scratch_worlds;
    Mat4[] palettes;
    float[] morph_weights;
}

<* Whether the crowd owns its complete runtime and part batches. *>
fn bool AnimatedCrowd.is_prepared(&self) => self.playback != null;

<*
 Publish placements and colors to every part without replacing identities.
 @param [&inout] crowd : "Contains complete runtime and valid placements."
 @require crowd.is_prepared()
*>
fn void Scene.write_crowd_batches(&self, AnimatedCrowd* crowd) {
    Aabb bounds = crowd.pose_bounds;
    foreach (usz index, placement : crowd.placements[:crowd.count]) {
        Aabb placed = maths::aabb_transform(crowd.pose_bounds, placement.to_mat4());
        bounds = index == 0 ? placed : maths::aabb_merge(bounds, placed);
    }

    foreach (&part : crowd.parts) {
        InstancedMesh* batch = self.world.get(part.batch, InstancedMesh);
        batch.transforms[:crowd.count] = crowd.placements[:crowd.count];
        batch.colors[:crowd.count] = crowd.colors[:crowd.count];
        batch.count = crowd.count;
        batch.local_bounds = bounds;
        self.mark_instances_dirty(self.node(part.batch));
    }

    if (crowd.parts.len) publish_crowd_lod_owner(self, self.node(crowd.parts[0].batch).parent, crowd);
}

fn void free_crowd(Entity entity, void* component, void* user) @private {
    AnimatedCrowd* crowd = component;
    CrowdRemovalContext* context = user;
    Allocator allocator = context.allocator;
    LodGroup* group = context.lod_groups.find(entity);
    if (group && group.state.animated) {
        group.state.count = 0;
        group.state.transforms = {};
        group.state.colors = {};
        publish_animated_lod_source(group.state);
    }

    if (crowd.playback) anim::destroy_crowd_playback(crowd.playback);
    if (crowd.authoring) anim::destroy_crowd_authoring(crowd.authoring);

    alloc::free(allocator, crowd.parts.ptr);
    alloc::free(allocator, crowd.scratch_worlds.ptr);
    alloc::free(allocator, crowd.palettes.ptr);
    alloc::free(allocator, crowd.placements.ptr);
    alloc::free(allocator, crowd.seeds.ptr);
    alloc::free(allocator, crowd.start_times.ptr);
    alloc::free(allocator, crowd.colors.ptr);
}

fn Node*? add_crowd_node(Scene* scene, Node* parent, String name) @private {
    if (!parent) parent = scene.root;

    Allocator allocator = scene.allocator;
    char[] label = alloc::new_array_try(allocator, char, name.len + 1) ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(allocator, label.ptr);

    label[:name.len] = name[..];
    label[name.len] = 0;

    Entity entity = scene.world.create_entity()!;
    Node* node = &scene.nodes[entity.index];
    *node = {
        .id = entity,
        .name = (String)label[:name.len],
        .transform_space = TransformSpace.PARENT,
        .local = maths::TRANSFORM_IDENTITY,
        .world = parent.world,
        .layers = DEFAULT_LAYERS,
        .visible = true,
        .visible_effective = parent.visible_effective,
    };

    link(node, parent);
    return node;
}
