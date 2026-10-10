module c3d::model;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::geometry;
import c3d::maths;
import c3d::scene @public;
import std::math;

<* Placement, base-action seed and tint of one crowd instance. *>
struct CrowdInstance {
    Transform placement;
    CrowdPose pose;
    Vec4 color;
}

<*
 Create animated model copies with one child batch per mesh.
 @param [&in] assets : "Owns the model and compatible seed clips."
 @param [&inout] scene : "Receives the complete prepared owner."
 @param pose_bounds : "Instance-local box covering every supported pose."
 @param [in] parent : "Null selects the scene root."
 @param name : "Copied into the scene allocator."
 @param trace : "Generated parts retain this trace opt-in."
 @param actions_per_instance : "Fixed concurrent actions per placement."
 @param event_capacity : "Fixed event entries across the whole crowd."
 @param authoring : "Optional copied explicit configuration, one per active instance."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require capacity > 0
*>
fn Node*? add_crowd(
    AssetStore* assets,
    Scene* scene,
    ModelId model,
    uint capacity,
    Aabb pose_bounds,
    CrowdInstance[] instances = {},
    Node* parent = null,
    String name = "",
    bool trace = false,
    uint actions_per_instance = anim::DEFAULT_CROWD_ACTIONS,
    uint event_capacity = anim::DEFAULT_CROWD_EVENT_CAPACITY,
    anim::CrowdInstanceAuthoring[] authoring = {},
) {
    ModelTemplate* template = &assets.models.try_get(model)!.data;
    check_crowd_configuration(capacity, actions_per_instance, pose_bounds)!;
    check_crowd_template(assets, template)!;
    check_instances(assets, template, capacity, instances)!;
    check_authoring(
        assets: assets,
        template: template,
        instances: instances,
        authoring: authoring,
        actions_per_instance: actions_per_instance,
    )!;

    Node* root = scene::add_crowd_node(scene, parent, name)!;
    defer catch scene.remove(root);

    attach_crowd(
        assets: assets,
        scene: scene,
        node: root,
        model: model,
        capacity: capacity,
        pose_bounds: pose_bounds,
        instances: instances,
        trace: trace,
        actions_per_instance: actions_per_instance,
        event_capacity: event_capacity,
        authoring: authoring,
    )!;
    prepare_crowd(assets, scene, root)!;
    return root;
}

<*
 Attach copied crowd authoring without preparing playback or part nodes.
 @param [&in] assets : "Resolves the model and compatible seed clips."
 @param [&inout] scene : "Owns copied authoring until removal."
 @param [&in] node : "Receives a pending AnimatedCrowd."
 @param pose_bounds : "Instance-local box covering every supported pose."
 @param trace : "Initial trace opt-in of every generated part."
 @param actions_per_instance : "Fixed concurrent actions per placement."
 @param event_capacity : "Fixed event entries across the whole crowd."
 @param authoring : "Optional copied explicit configuration, one per active instance."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require !scene.has(node, AnimatedCrowd)
*>
fn void? attach_crowd(
    AssetStore* assets,
    Scene* scene,
    Node* node,
    ModelId model,
    uint capacity,
    Aabb pose_bounds,
    CrowdInstance[] instances = {},
    bool trace = false,
    uint actions_per_instance = anim::DEFAULT_CROWD_ACTIONS,
    uint event_capacity = anim::DEFAULT_CROWD_EVENT_CAPACITY,
    anim::CrowdInstanceAuthoring[] authoring = {},
) {
    ModelTemplate* template = &assets.models.try_get(model)!.data;
    check_crowd_configuration(capacity, actions_per_instance, pose_bounds)!;
    check_crowd_template(assets, template)!;
    check_instances(assets, template, capacity, instances)!;
    check_authoring(
        assets: assets,
        template: template,
        instances: instances,
        authoring: authoring,
        actions_per_instance: actions_per_instance,
    )!;

    Allocator allocator = scene.allocator;
    AnimatedCrowd crowd = {
        .model = model,
        .pose_bounds = pose_bounds,
        .trace = trace,
        .actions_per_instance = actions_per_instance,
        .event_capacity = event_capacity,
    };
    defer catch {
        alloc::free(allocator, crowd.placements.ptr);
        alloc::free(allocator, crowd.seeds.ptr);
        alloc::free(allocator, crowd.start_times.ptr);
        alloc::free(allocator, crowd.colors.ptr);
        if (crowd.authoring) anim::destroy_crowd_authoring(crowd.authoring);
    }

    crowd.placements = alloc::new_array_try(allocator, Transform, (sz)capacity)
      ?? c3d::CAPACITY_EXCEEDED~!;
    crowd.seeds = alloc::new_array_try(allocator, CrowdPose, (sz)capacity)
      ?? c3d::CAPACITY_EXCEEDED~!;
    crowd.start_times = alloc::new_array_try(allocator, float, (sz)capacity)
      ?? c3d::CAPACITY_EXCEEDED~!;
    crowd.colors = alloc::new_array_try(allocator, Vec4, (sz)capacity)
      ?? c3d::CAPACITY_EXCEEDED~!;

    crowd.placements[..] = maths::TRANSFORM_IDENTITY;
    crowd.seeds[..] = { .speed = 1, .loop = true };
    crowd.colors[..] = (Vec4){ 1, 1, 1, 1 };
    fill_crowd_authoring(&crowd, instances);
    if (authoring.len) crowd.authoring = anim::copy_crowd_authoring(allocator, authoring)!;

    scene.add(node, crowd);
}

<*
 Prepare all mesh parts and playback atomically for one pending owner.
 @param [&in] assets : "Owns the model, referenced assets and seed clips."
 @param [&inout] scene : "Receives complete runtime or retains pending authoring."
 @param [&in] node : "Carries AnimatedCrowd."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require scene.has(node, AnimatedCrowd)
*>
fn void? prepare_crowd(AssetStore* assets, Scene* scene, Node* node) {
    AnimatedCrowd crowd = *scene.get(node, AnimatedCrowd);
    if (crowd.is_prepared()) return;

    ModelTemplate* template = &assets.models.try_get(crowd.model)!.data;
    uint capacity = (uint)crowd.placements.len;
    check_crowd_configuration(capacity, crowd.actions_per_instance, crowd.pose_bounds)!;
    check_crowd_template(assets, template)!;
    foreach (seed : crowd.seeds[:crowd.count]) anim::validate_crowd_seed(assets, template, seed)!;
    if (crowd.authoring) {
        foreach (index, source : crowd.authoring.instances) {
            anim::validate_crowd_authoring(
                assets: assets,
                template: template,
                source: source,
                actions_per_instance: crowd.actions_per_instance,
                placement: crowd.placements[index],
            )!;
        }
    }

    Allocator allocator = scene.allocator;
    defer catch {
        foreach (part : crowd.parts) {
            if (part.batch.generation) scene.remove(scene.node(part.batch));
        }

        if (crowd.playback) anim::destroy_crowd_playback(crowd.playback);
        alloc::free(allocator, crowd.parts.ptr);
        alloc::free(allocator, crowd.scratch_worlds.ptr);
        alloc::free(allocator, crowd.palettes.ptr);
    }

    crowd.playback = anim::create_crowd_playback(
        allocator: allocator,
        template: template,
        placements: crowd.placements,
        actions_per_instance: crowd.actions_per_instance,
        event_capacity: crowd.event_capacity,
    )!;
    crowd.parts = alloc::new_array_try(allocator, CrowdPart, template.meshes.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    crowd.scratch_worlds = alloc::new_array_try(allocator, Mat4, template.nodes.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    crowd.joint_count = template.skins.len ? (uint)template.skins[0].joint_nodes.len : 0;
    crowd.palettes = alloc::new_array_try(allocator, Mat4, (sz)capacity * crowd.joint_count)
      ?? c3d::CAPACITY_EXCEEDED~!;
    crowd.morph_weights = crowd.playback.weight_values;

    foreach (uint index, &mesh : template.meshes) {
        uint weight_count = (uint)mesh.default_morph_weights.len;
        crowd.parts[index] = {
            .template_node = mesh.node,
            .mesh_index = index,
            .skinned = mesh_is_skinned(assets, template, mesh),
            .weight_count = weight_count,
            .weight_offset = crowd.morph_stride,
        };
        crowd.morph_stride += weight_count;
    }

    crowd.playback.count = crowd.count;
    foreach (uint index, seed : crowd.seeds[:crowd.count]) {
        if (crowd.authoring && crowd.authoring.instances[index].configured) {
            anim::restore_crowd_authoring(
                state: crowd.playback,
                index: index,
                assets: assets,
                source: crowd.authoring.instances[index],
                base_start: crowd.start_times[index],
            )!;
            continue;
        }

        anim::Action action = anim::prepare_crowd_seed(
            state: crowd.playback,
            index: index,
            assets: assets,
            seed: seed,
        )!;
        anim::install_crowd_seed(crowd.playback, index, action);
    }

    crowd.playback.update(assets, 0);

    foreach (index, &mesh : template.meshes) {
        Node* part = add_crowd_batch(
            scene: scene,
            parent: node,
            mesh: mesh,
            capacity: capacity,
            name: template.nodes[mesh.node].name,
            trace: crowd.trace,
        )!;
        crowd.parts[index].batch = part.id;
    }

    if (crowd.authoring) {
        anim::destroy_crowd_authoring(crowd.authoring);
        crowd.authoring = null;
    }

    *scene.get(node, AnimatedCrowd) = crowd;
    anim::publish_crowd_pose(assets, scene, scene.get(node, AnimatedCrowd));
}

<*
 Prepare pending crowds in a subtree, retaining successful owners.
 @param [&in] assets : "Owns the models and compatible seed clips."
 @param [&inout] scene : "Prepared owners remain unchanged."
 @param [in] root : "Null selects the scene root."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? prepare_crowd_subtree(AssetStore* assets, Scene* scene, Node* root = null) {
    if (!root) root = scene.root;
    fault failure;

    scene.@each(AnimatedCrowd; entity, crowd) {
        Node* node = scene.node(entity);
        Node* ancestor = node;
        while (ancestor && ancestor != root) ancestor = ancestor.parent;

        if (ancestor) {
            if (catch excuse = prepare_crowd(assets, scene, node)) {
                if (!failure) failure = excuse;
            }
        }
    };

    if (failure) return failure~;
}

<*
 Replace instances with fresh playback while retaining fixed runtime storage.
 @param [&in] assets : "Owns destination-compatible seed clips."
 @param [&inout] scene : "Receives one complete replacement."
 @param [&in] node : "Carries pending or prepared AnimatedCrowd."
 @param instances : "Copied; omitted capacity slots become inactive."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require scene.has(node, AnimatedCrowd)
*>
fn void? set_crowd(
    AssetStore* assets,
    Scene* scene,
    Node* node,
    CrowdInstance[] instances,
) {
    AnimatedCrowd* crowd = scene.get(node, AnimatedCrowd);
    ModelTemplate* template = &assets.models.try_get(crowd.model)!.data;
    check_crowd_template(assets, template)!;
    check_instances(assets, template, (uint)crowd.placements.len, instances)!;

    if (!crowd.is_prepared()) {
        if (crowd.authoring) {
            anim::destroy_crowd_authoring(crowd.authoring);
            crowd.authoring = null;
        }

        fill_crowd_authoring(crowd, instances);
        return;
    }

    @pool() {
        anim::Action[] staged = alloc::new_array_try(tmem, anim::Action, instances.len)
          ?? c3d::CAPACITY_EXCEEDED~!;
        defer {
            foreach (&action : staged) anim::release_prepared_action(crowd.playback.allocator, action);
        }

        foreach (uint index, instance : instances) {
            staged[index] = anim::prepare_crowd_seed(
                state: crowd.playback,
                index: index,
                assets: assets,
                seed: instance.pose,
            )!;
        }

        for (uint index = 0; index < crowd.playback.slots.len; index++) {
            anim::reset_crowd_playback_slot(crowd.playback, index);
        }

        foreach (uint index, &action : staged) {
            anim::install_crowd_seed(crowd.playback, index, *action);
            *action = {};
        }

        fill_crowd_authoring(crowd, instances);
        crowd.playback.count = crowd.count;
        crowd.playback.update(assets, 0);
        anim::publish_crowd_pose(assets, scene, crowd);
    };
}

fn void? check_crowd_configuration(uint capacity, uint actions_per_instance, Aabb bounds) @local {
    if (!capacity || !actions_per_instance || actions_per_instance > anim::MAX_ACTIONS) {
        return c3d::INVALID_ARGUMENT~;
    }

    for (uint axis = 0; axis < 3; axis++) {
        if (!math::is_finite(bounds.min[axis]) || !math::is_finite(bounds.max[axis])
          || bounds.min[axis] > bounds.max[axis]) return c3d::INVALID_ARGUMENT~;
    }
}

fn void? check_crowd_template(AssetStore* assets, ModelTemplate* template) @local {
    if (!template.nodes.len || !template.meshes.len || template.nodes.len > uint::max
      || template.meshes.len > uint::max) return c3d::INVALID_ARGUMENT~;

    foreach (index, node : template.nodes) {
        if (node.parent < -1 || node.parent >= (int)index) return c3d::INVALID_ARGUMENT~;
    }

    usz weight_stride;
    foreach (index, &mesh : template.meshes) {
        if (mesh.node >= template.nodes.len) return c3d::INVALID_ARGUMENT~;
        foreach (previous : template.meshes[:index]) {
            if (previous.node == mesh.node) return c3d::INVALID_ARGUMENT~;
        }

        GeometryAsset* geometry = assets.geometries.try_get(mesh.geometry)!;
        assets.materials.try_get(mesh.material)!;
        usz width = geometry.data.channels.len ? geometry.data.channels.len : geometry.target_count;
        if (mesh.default_morph_weights.len != width) return c3d::INVALID_ARGUMENT~;
        foreach (weight : mesh.default_morph_weights) {
            if (!math::is_finite(weight)) return c3d::INVALID_ARGUMENT~;
        }

        foreach (channel_index, channel : geometry.data.channels) {
            if (!channel.name.len) continue;
            foreach (previous : geometry.data.channels[:channel_index]) {
                if (previous.name == channel.name) return c3d::INVALID_ARGUMENT~;
            }
        }

        weight_stride += width;
        if (weight_stride > uint::max) return c3d::CAPACITY_EXCEEDED~;
    }

    ModelSkin* first;
    Skeleton* first_skeleton;
    foreach (&skin : template.skins) {
        if (catch mesh_of(template, skin.mesh_node)) return c3d::INVALID_ARGUMENT~;
        Skeleton* skeleton = &assets.skeletons.try_get(skin.skeleton)!.data;
        if (!skin.joint_nodes.len || skin.joint_nodes.len != skeleton.inverse_bind.len) {
            return c3d::INVALID_ARGUMENT~;
        }
        foreach (joint : skin.joint_nodes) {
            if (joint >= template.nodes.len) return c3d::INVALID_ARGUMENT~;
        }

        if (!first) {
            first = skin;
            first_skeleton = skeleton;
        } else {
            if (!same_joints(first.joint_nodes, skin.joint_nodes)) return c3d::INVALID_ARGUMENT~;

            sz bind_bytes = (sz)(skin.joint_nodes.len * Mat4::size);
            if (!mem::equals(first_skeleton.inverse_bind.ptr, skeleton.inverse_bind.ptr, bind_bytes)) {
                return c3d::INVALID_ARGUMENT~;
            }
        }

        ModelMesh* mesh = mesh_of(template, skin.mesh_node)!;
        if (assets.geometry(mesh.geometry).skin_bounds.joints.len > skin.joint_nodes.len) {
            return c3d::INVALID_ARGUMENT~;
        }
    }
}

fn void? check_instances(
    AssetStore* assets,
    ModelTemplate* template,
    uint capacity,
    CrowdInstance[] instances,
) @local {
    if (instances.len > capacity) return c3d::INVALID_ARGUMENT~;

    foreach (instance : instances) anim::validate_crowd_seed(assets, template, instance.pose)!;
}

fn void? check_authoring(
    AssetStore* assets,
    ModelTemplate* template,
    CrowdInstance[] instances,
    anim::CrowdInstanceAuthoring[] authoring,
    uint actions_per_instance,
) @local {
    if (!authoring.len) return;
    if (authoring.len != instances.len) return c3d::INVALID_ARGUMENT~;

    foreach (index, source : authoring) {
        anim::validate_crowd_authoring(
            assets: assets,
            template: template,
            source: source,
            actions_per_instance: actions_per_instance,
            placement: instances[index].placement,
        )!;
    }
}

fn void fill_crowd_authoring(AnimatedCrowd* crowd, CrowdInstance[] instances) @local {
    foreach (usz index, instance : instances) {
        crowd.placements[index] = instance.placement;
        crowd.seeds[index] = instance.pose;
        crowd.start_times[index] = instance.pose.time;
        crowd.colors[index] = instance.color;
    }

    crowd.count = (uint)instances.len;
}

fn bool mesh_is_skinned(AssetStore* assets, ModelTemplate* template, ModelMesh* mesh) @local {
    if (!assets.geometry(mesh.geometry).skin_bounds.joints.len) return false;

    foreach (skin : template.skins) {
        if (skin.mesh_node == mesh.node) return true;
    }

    return false;
}

fn bool same_joints(uint[] first, uint[] second) @local {
    if (first.len != second.len) return false;

    foreach (index, joint : first) {
        if (joint != second[index]) return false;
    }

    return true;
}

fn ModelMesh*? mesh_of(ModelTemplate* template, uint node) @local {
    foreach (&mesh : template.meshes) {
        if (mesh.node == node) return mesh;
    }

    return NOT_FOUND~;
}

fn Node*? add_crowd_batch(
    Scene* scene,
    Node* parent,
    ModelMesh* mesh,
    uint capacity,
    String name,
    bool trace,
) @local {
    Allocator allocator = scene.allocator;
    Transform[] transforms = alloc::new_array_try(allocator, Transform, (sz)capacity)
      ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(allocator, transforms.ptr);
    Vec4[] colors = alloc::new_array_try(allocator, Vec4, (sz)capacity)
      ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(allocator, colors.ptr);

    transforms[..] = maths::TRANSFORM_IDENTITY;
    colors[..] = (Vec4){ 1, 1, 1, 1 };

    Node* node = scene::add_crowd_node(scene, parent, name)!;

    scene.add(node, (InstancedMesh){
        .geometry = mesh.geometry,
        .material = mesh.material,
        .transforms = transforms,
        .colors = colors,
        .cast_shadow = true,
        .receive_shadow = true,
        .trace = trace,
        .has_bounds_override = true,
        .revision = 1,
    });
    return node;
}
