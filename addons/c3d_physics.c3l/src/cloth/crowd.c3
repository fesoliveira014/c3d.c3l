module c3d::physics::cloth;

import c3d;
import c3d::anim;
import c3d::asset;
import c3d::ecs;
import c3d::geometry;
import c3d::maths;
import c3d::physics @public;
import c3d::scene;
import std::math;
import std::time;
import std::time::clock;

<* Authored cloth configuration for one logical crowd part. *>
struct CrowdClothPartDesc {
    uint      part;
    ClothDesc cloth;
}

<* Per-part cloth authoring and prepared per-slot runtime on a crowd owner. *>
struct CrowdClothPart {
    ClothAuthoring* authoring;
    uint            part;
    ModelId         model;
    uint            model_revision;
    GeometryId      source;
    uint            source_revision;
    bool            skinned;
    SkeletonId      skeleton;
    uint            skeleton_revision;
    uint            joint_count;
    uint            template_node;
    MaterialId      material;
    bool            cast_shadow;
    bool            receive_shadow;
    bool            trace;
    bool            prepared;
    void*           playback_identity;
    uint            capacity;
    Entity          original_batch;
    bool            original_visible;
    ClothState*[]   states;
    Entity[]        outputs;
    uint[]          slot_generations;
    Vec4[]          published_colors;
    Vec4[]          source_colors;
    SkinMat4[]      palette_scratch;
}

<* Heap state of a CrowdCloth component. *>
struct CrowdClothState {
    CrowdClothPart[] parts;
}

<* Multi-part cloth attachment on an AnimatedCrowd owner node. *>
struct CrowdCloth {
    CrowdClothState* state;
}

<* Whether every attached crowd cloth part owns prepared runtime storage. *>
fn bool CrowdCloth.is_prepared(&self) {
    if (!self.state || !self.state.parts.len) return false;
    foreach (&part : self.state.parts) {
        if (!part.prepared) return false;
    }
    return true;
}

<*
 Borrow one attached crowd cloth part by template mesh index.
 @return? NOT_FOUND
*>
fn CrowdClothPart*? CrowdCloth.find_part(&self, uint part) {
    if (!self.state) return NOT_FOUND~;
    foreach (&entry : self.state.parts) {
        if (entry.part == part) return entry;
    }
    return NOT_FOUND~;
}

<*
 Attach copied cloth authoring for one logical mesh part of an AnimatedCrowd owner.
 @param [&inout] self : "Scene with physics registered."
 @param [&in] assets : "Resolves the crowd model, part geometry, skeleton and material."
 @param [&in] owner : "Live node carrying AnimatedCrowd."
 @param part : "Logical mesh index in the crowd model."
 @param desc : "Authored cloth configuration."
 @return? NO_MESH, CLOTH_EXISTS, physics::SOURCE_UNAVAILABLE
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require self.world.is_registered(CrowdCloth)
*>
fn void? Scene.attach_crowd_cloth(
    &self,
    AssetStore* assets,
    Node* owner,
    uint part,
    ClothDesc desc = default_cloth_desc(),
) {
    if (node_in_lod_group(self, owner)) return c3d::UNSUPPORTED~;
    AnimatedCrowd* crowd = self.get(owner, AnimatedCrowd);
    if (!crowd) return NO_MESH~;
    if (self.has(owner, CrowdCloth)) {
        if (try self.get(owner, CrowdCloth).find_part(part)) return CLOTH_EXISTS~;
    }

    check_cloth_desc(desc)!;
    check_collider_owners(self, desc.colliders)!;

    ModelAsset* model_record = assets.models.try_get(crowd.model)!;
    ModelTemplate* template = &model_record.data;
    if (part >= template.meshes.len) return c3d::INVALID_ARGUMENT~;

    ModelMesh* model_mesh = &template.meshes[part];
    if (model_mesh.default_morph_weights.len) return c3d::UNSUPPORTED~;
    check_cloth_material(assets, model_mesh.material, true)!;

    GeometryAsset* source = assets.geometries.try_get(model_mesh.geometry)!;
    Geometry* data = &source.data;
    if (!data.positions.len) return physics::SOURCE_UNAVAILABLE~;
    if (data.targets.len || source.target_count || data.channels.len || data.custom_data.len) {
        return c3d::UNSUPPORTED~;
    }
    if (data.topology != Topology.TRIANGLES || !data.indices.len) return c3d::UNSUPPORTED~;
    if (data.indices.len % 3) return c3d::INVALID_ARGUMENT~;
    foreach (index : data.indices) {
        if (index >= data.positions.len) return c3d::INVALID_ARGUMENT~;
    }
    foreach (position : data.positions) {
        if (!finite_vector(position)) return c3d::INVALID_ARGUMENT~;
    }

    bool skinned;
    SkeletonId skeleton;
    uint skeleton_revision;
    uint joint_count;
    foreach (&skin : template.skins) {
        if (skin.mesh_node == model_mesh.node) {
            skinned = true;
            skeleton = skin.skeleton;
            SkeletonAsset* skel_record = assets.skeletons.try_get(skin.skeleton)!;
            skeleton_revision = skel_record.header.revision;
            joint_count = (uint)skin.joint_nodes.len;
            check_skin_geometry(data, skin.joint_nodes.len)!;
            break;
        }
    }
    if (!skinned) {
        if (data.joints.len || data.weights.len || source.shape.skinned) return c3d::UNSUPPORTED~;
    }

    if (crowd.is_prepared()) {
        if (part >= crowd.parts.len) return c3d::INVALID_ARGUMENT~;
        Entity batch_entity = crowd.parts[part].batch;
        if (!self.world.is_alive(batch_entity)) return NO_MESH~;
        Node* batch_node = self.node(batch_entity);
        InstancedMesh* batch = self.get(batch_node, InstancedMesh);
        if (!batch) return NO_MESH~;
        if (batch.sway.amplitude != 0 || batch.fade.end != 0) return c3d::UNSUPPORTED~;
        check_cloth_material(assets, batch.material, true)!;
    }

    @pool() {
        check_cloth_authoring(data, desc)!;
    };

    ClothAuthoring* authoring = copy_authoring(self.allocator, desc)!;
    defer catch alloc::free(self.allocator, authoring);
    authoring.source = model_mesh.geometry;
    authoring.source_revision = source.header.revision;
    authoring.skinned = skinned;
    authoring.skeleton = skeleton;
    authoring.skeleton_revision = skeleton_revision;

    CrowdClothPart part_record = {
        .authoring         = authoring,
        .part              = part,
        .model             = crowd.model,
        .model_revision    = model_record.header.revision,
        .source            = model_mesh.geometry,
        .source_revision   = source.header.revision,
        .skinned           = skinned,
        .skeleton          = skeleton,
        .skeleton_revision = skeleton_revision,
        .joint_count       = joint_count,
        .template_node     = model_mesh.node,
        .material          = model_mesh.material,
        .cast_shadow       = true,
        .receive_shadow    = true,
        .trace             = crowd.trace,
    };

    if (!self.has(owner, CrowdCloth)) {
        CrowdClothState* state = alloc::new_try(self.allocator, CrowdClothState) ?? c3d::CAPACITY_EXCEEDED~!;
        defer catch alloc::free(self.allocator, state);
        CrowdClothPart[] parts = alloc::new_array_try(self.allocator, CrowdClothPart, 1) ?? c3d::CAPACITY_EXCEEDED~!;
        parts[0] = part_record;
        state.parts = parts;
        self.add(owner, (CrowdCloth){ .state = state });
        return;
    }

    CrowdCloth* component = self.get(owner, CrowdCloth);
    usz old_len = component.state.parts.len;
    CrowdClothPart[] next_parts = alloc::new_array_try(self.allocator, CrowdClothPart, (sz)(old_len + 1))
        ?? c3d::CAPACITY_EXCEEDED~!;
    if (old_len) next_parts[:old_len] = component.state.parts[..];
    next_parts[old_len] = part_record;
    alloc::free(self.allocator, component.state.parts.ptr);
    component.state.parts = next_parts;
}

<*
 Prepare pending crowd cloth parts on an AnimatedCrowd owner and hide replaced part batches.
 @param [&inout] world : "Physics world owning the scene and store."
 @param [&inout] assets : "Owns the model, source geometries and private per-slot copies."
 @param [&in] owner : "Live node carrying AnimatedCrowd and CrowdCloth."
 @param part : "Specific logical part index, or uint::max to prepare all pending parts."
 @return? NO_MESH, OWNERSHIP_CHANGED, physics::SOURCE_UNAVAILABLE, physics::NO_BODY
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn void? prepare_crowd_cloth(
    PhysicsWorld* world,
    AssetStore* assets,
    Node* owner,
    uint part = uint::max,
) {
    if (!world || world.assets != assets || !world.scene.has(owner, CrowdCloth)) {
        return c3d::INVALID_ARGUMENT~;
    }
    Scene* scene = world.scene;
    if (node_in_lod_group(scene, owner)) return c3d::UNSUPPORTED~;

    AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
    if (!crowd) return NO_MESH~;
    if (!crowd.is_prepared()) return c3d::INVALID_ARGUMENT~;

    CrowdCloth* component = scene.get(owner, CrowdCloth);
    if (!component.state || !component.state.parts.len) return c3d::INVALID_ARGUMENT~;

    if (part != uint::max) {
        CrowdClothPart*? found = component.find_part(part);
        if (catch found) return c3d::INVALID_ARGUMENT~;
        if (found.prepared) return;
        prepare_crowd_cloth_part(world, assets, owner, crowd, found)!;
        return;
    }

    fault failure;
    foreach (&entry : component.state.parts) {
        if (entry.prepared) continue;
        if (catch excuse = prepare_crowd_cloth_part(world, assets, owner, crowd, entry)) {
            if (!failure) failure = excuse;
        }
    }
    if (failure) return failure~;
}

<*
 Restore replaced crowd part batches and remove one or all crowd cloth parts.
 @param [&in] owner : "Live node carrying CrowdCloth."
 @param part : "Specific logical part index, or uint::max to remove all parts."
 @require self.has(owner, CrowdCloth)
*>
fn void Scene.remove_crowd_cloth(&self, Node* owner, uint part = uint::max) {
    CrowdCloth* component = self.get(owner, CrowdCloth);
    if (!component.state || !component.state.parts.len) {
        self.remove_component(owner, CrowdCloth);
        return;
    }

    if (part == uint::max) {
        foreach (&entry : component.state.parts) {
            release_crowd_cloth_part(self, owner, entry, true);
            alloc::free(self.allocator, entry.authoring);
            *entry = {};
        }
        alloc::free(self.allocator, component.state.parts.ptr);
        component.state.parts = {};
        self.remove_component(owner, CrowdCloth);
        return;
    }

    usz found_index = component.state.parts.len;
    foreach (usz index, &entry : component.state.parts) {
        if (entry.part == part) {
            found_index = index;
            break;
        }
    }
    if (found_index == component.state.parts.len) return;

    CrowdClothPart* target = &component.state.parts[found_index];
    release_crowd_cloth_part(self, owner, target, true);
    alloc::free(self.allocator, target.authoring);

    if (component.state.parts.len == 1) {
        alloc::free(self.allocator, component.state.parts.ptr);
        component.state.parts = {};
        self.remove_component(owner, CrowdCloth);
        return;
    }

    usz next_len = component.state.parts.len - 1;
    CrowdClothPart[] next_parts = alloc::new_array(self.allocator, CrowdClothPart, (sz)next_len);
    usz cursor;
    foreach (usz index, entry : component.state.parts) {
        if (index == found_index) continue;
        next_parts[cursor++] = entry;
    }
    alloc::free(self.allocator, component.state.parts.ptr);
    component.state.parts = next_parts;
}

fn void free_crowd_cloth(Entity entity, void* raw, void* user) @private {
    CrowdCloth* component = (CrowdCloth*)raw;
    Allocator allocator = *(Allocator*)user;
    if (!component.state) return;

    foreach (&entry : component.state.parts) {
        destroy_crowd_cloth_part_storage(allocator, entry);
        alloc::free(allocator, entry.authoring);
    }
    alloc::free(allocator, component.state.parts.ptr);
    alloc::free(allocator, component.state);
    *component = {};
}

fn void destroy_crowd_cloth_part_storage(Allocator allocator, CrowdClothPart* part_rec) @local {
    foreach (state : part_rec.states) {
        if (!state) continue;
        if (state.assets && state.assets.geometries.is_live(state.geometry)) {
            state.assets.remove_geometry(state.geometry);
        }
        alloc::free(allocator, state);
    }
    alloc::free(allocator, part_rec.states.ptr);
    alloc::free(allocator, part_rec.outputs.ptr);
    alloc::free(allocator, part_rec.slot_generations.ptr);
    alloc::free(allocator, part_rec.published_colors.ptr);
    alloc::free(allocator, part_rec.source_colors.ptr);
    alloc::free(allocator, part_rec.palette_scratch.ptr);
    part_rec.states = {};
    part_rec.outputs = {};
    part_rec.slot_generations = {};
    part_rec.published_colors = {};
    part_rec.source_colors = {};
    part_rec.palette_scratch = {};
    part_rec.prepared = false;
}

fn void release_crowd_cloth_part(
    Scene* scene,
    Node* owner,
    CrowdClothPart* part_rec,
    bool restore_batch,
) @local {
    foreach (out_entity : part_rec.outputs) {
        if (out_entity.generation && scene.world.is_alive(out_entity)) {
            Node* out_node = scene.node(out_entity);
            if (out_node.parent == owner) scene.remove(out_node);
        }
    }
    if (restore_batch && part_rec.prepared
        && part_rec.original_batch.generation && scene.world.is_alive(part_rec.original_batch)) {
        Node* batch_node = scene.node(part_rec.original_batch);
        if (batch_node.parent == owner) {
            batch_node.visible = part_rec.original_visible;
            batch_node.visible_effective = owner.visible_effective && part_rec.original_visible;
        }
    }
    destroy_crowd_cloth_part_storage(scene.allocator, part_rec);
}

fn void? prepare_crowd_cloth_part(
    PhysicsWorld* world,
    AssetStore* assets,
    Node* owner,
    AnimatedCrowd* crowd,
    CrowdClothPart* part_rec,
) @local {
    Scene* scene = world.scene;
    if (!c3d::same_id(crowd.model, part_rec.model)) return c3d::INVALID_ID~;
    ModelAsset* model_record = assets.models.try_get(part_rec.model)!;
    if (model_record.header.revision != part_rec.model_revision) return c3d::INVALID_ID~;
    if (part_rec.part >= crowd.parts.len || part_rec.part >= model_record.data.meshes.len) {
        return c3d::INVALID_ARGUMENT~;
    }

    CrowdPart* crowd_part = &crowd.parts[part_rec.part];
    if (crowd_part.skinned != part_rec.skinned || crowd_part.template_node != part_rec.template_node) {
        return c3d::INVALID_ID~;
    }
    if (!scene.world.is_alive(crowd_part.batch)) return NO_MESH~;
    Node* batch_node = scene.node(crowd_part.batch);
    if (batch_node.parent != owner) return OWNERSHIP_CHANGED~;
    InstancedMesh* batch = scene.get(batch_node, InstancedMesh);
    if (!batch) return NO_MESH~;
    if (batch.sway.amplitude != 0 || batch.fade.end != 0) return c3d::UNSUPPORTED~;
    if (!c3d::same_id(batch.geometry, part_rec.source)) return c3d::INVALID_ID~;
    check_cloth_material(assets, batch.material, true)!;

    GeometryAsset* source = assets.geometries.try_get(part_rec.source)!;
    if (source.header.revision != part_rec.source_revision) return c3d::INVALID_ID~;

    if (part_rec.skinned) {
        SkeletonAsset* skel_record = assets.skeletons.try_get(part_rec.skeleton)!;
        if (skel_record.header.revision != part_rec.skeleton_revision) return c3d::INVALID_ID~;
        if (crowd.joint_count != part_rec.joint_count) return c3d::INVALID_ARGUMENT~;
        check_skin_geometry(&source.data, part_rec.joint_count)!;
    }

    uint capacity = (uint)crowd.placements.len;
    if (!capacity || crowd.count > capacity || crowd.colors.len < capacity) return c3d::INVALID_ARGUMENT~;

    ClothDesc desc = part_rec.authoring.desc;
    check_cloth_desc(desc)!;
    check_collider_owners(scene, desc.colliders)!;

    @pool() {
        check_seams(desc.seams, (uint)source.data.positions.len)!;
        ClothMaterialPlan material_plan = build_material_plan(&source.data, desc)!;
        uint particle_count = material_plan.particle_count;
        check_transport_authoring(desc.transport, particle_count)!;
        ClothAttachmentPlan attachment_plan = build_attachment_plan(
            legacy_pins:        desc.pins,
            render_to_particle: material_plan.render_to_particle,
            attachments:        desc.attachments,
            particle_count:     particle_count,
        )!;

        Vec3[] rest = alloc::new_array(tmem, Vec3, (sz)particle_count);
        Vec3[] edge_positions = alloc::new_array(tmem, Vec3, (sz)particle_count);
        foreach (particle, source_vertex : material_plan.particle_sources) {
            Vec3 local_pos = source.data.positions[source_vertex];
            rest[particle] = local_pos;
            edge_positions[particle] = maths::transform_point(owner.world, local_pos);
        }
        check_world_positions(edge_positions)!;

        ClothTopology topology = build_topology(
            data:               &source.data,
            render_to_particle: material_plan.render_to_particle,
            rest_positions:     rest,
            edge_positions:     edge_positions,
            world_positions:    {},
            desc:               desc,
        )!;
        ClothCapture capture = capture_colliders(
            scene:      scene,
            owners:     desc.colliders,
            max_shapes: desc.collisions.max_shapes,
            world:      world,
        )!;

        Allocator allocator = scene.allocator;
        uint material_vertex_count = material_plan.material_vertex_count;
        part_rec.states = alloc::new_array_try(allocator, ClothState*, (sz)capacity) ?? c3d::CAPACITY_EXCEEDED~!;
        defer catch release_crowd_cloth_part(scene, owner, part_rec, false);

        part_rec.outputs = alloc::new_array_try(allocator, Entity, (sz)capacity) ?? c3d::CAPACITY_EXCEEDED~!;
        part_rec.slot_generations = alloc::new_array_try(allocator, uint, (sz)capacity) ?? c3d::CAPACITY_EXCEEDED~!;
        part_rec.published_colors = alloc::new_array_try(allocator, Vec4, (sz)capacity) ?? c3d::CAPACITY_EXCEEDED~!;
        part_rec.source_colors = alloc::new_array_try(allocator, Vec4, (sz)material_vertex_count)
            ?? c3d::CAPACITY_EXCEEDED~!;
        if (part_rec.skinned && part_rec.joint_count) {
            part_rec.palette_scratch = alloc::new_array_try(allocator, SkinMat4, (sz)part_rec.joint_count)
                ?? c3d::CAPACITY_EXCEEDED~!;
        }

        if (material_plan.geometry.colors.len == material_vertex_count) {
            part_rec.source_colors[..] = material_plan.geometry.colors[..];
        } else {
            part_rec.source_colors[..] = { 1, 1, 1, 1 };
            material_plan.geometry.colors = part_rec.source_colors;
        }

        for (uint slot = 0; slot < capacity; slot++) {
            GeometryId copy = assets.add_geometry(&material_plan.geometry)!;
            bool state_linked;
            defer catch if (!state_linked && assets.geometries.is_live(copy)) assets.remove_geometry(copy);

            ClothState* state = allocate_cloth_state(
                allocator:             allocator,
                vertex_count:          particle_count,
                source_vertex_count:   (uint)source.data.positions.len,
                material_vertex_count: material_vertex_count,
                normal_domain_count:   material_plan.normal_domain_count,
                corner_count:          (uint)material_plan.corners.len,
                pin_count:             (uint)attachment_plan.pins.len,
                soft_count:            (uint)attachment_plan.soft.len,
                edge_count:            (uint)topology.edges.len,
                face_count:            (uint)(source.data.indices.len / 3),
                bend_count:            (uint)topology.bends.len,
                hinge_count:           (uint)topology.hinges.len,
                body_count:            (uint)capture.bodies.len,
                joint_count:           part_rec.skinned ? part_rec.joint_count : 0,
                tangent_frame:         desc.tangent_frame,
                crowd:                 true,
                collisions:            desc.collisions,
            )!;
            state_linked = true;
            part_rec.states[slot] = state;

            state.desc = desc;
            state.desc.pins = state.pins;
            state.colliders[..] = desc.colliders[..];
            state.desc.colliders = state.colliders;
            state.bodies[..] = capture.bodies[..];
            state.staged_bodies[..] = capture.bodies[..];
            state.shapes = state.shape_storage[:capture.shapes.len];
            state.shapes[..] = capture.shapes[..];
            state.assets = assets;
            state.source = part_rec.source;
            state.source_revision = part_rec.source_revision;
            state.geometry = copy;
            state.skinned = part_rec.skinned;
            state.crowd = true;
            state.skeleton = part_rec.skeleton;
            state.skeleton_revision = part_rec.skeleton_revision;
            state.render_to_particle[..] = material_plan.render_to_particle[..];
            state.particle_sources[..] = material_plan.particle_sources[..];
            if (desc.transport.len) {
                state.transport[..] = desc.transport[..];
            } else {
                state.transport[..] = 0;
            }
            state.desc.transport = state.transport;

            state.rest[..] = rest[..];
            state.solved_reference[..] = edge_positions[..];
            state.published_reference[..] = edge_positions[..];
            state.current_reference[..] = edge_positions[..];
            state.positions[..] = edge_positions[..];
            state.predicted[..] = edge_positions[..];
            state.accelerations[..] = (Vec3){};
            state.published[..] = edge_positions[..];
            if (desc.collisions.continuous) {
                state.sweep_start[..] = edge_positions[..];
                foreach (index, point : edge_positions) {
                    state.sweep_bounds[index] = { .min = point, .max = point };
                }
            }
            state.published_frame = owner.world;
            state.inverse_masses[..] = 1;
            state.pins[..] = attachment_plan.pins[..];
            foreach (pin_slot, pin : attachment_plan.pins) {
                state.inverse_masses[pin] = 0;
                state.pin_anchors[pin_slot] = edge_positions[pin];
                state.pin_targets[pin_slot] = edge_positions[pin];
            }
            state.soft_attachments[..] = attachment_plan.soft[..];
            foreach (soft_slot, attachment : attachment_plan.soft) {
                state.soft_anchors[soft_slot] = edge_positions[attachment.particle];
                state.soft_targets[soft_slot] = edge_positions[attachment.particle];
                state.soft_lambdas[soft_slot] = {};
            }
            state.edges[..] = topology.edges[..];
            state.bends[..] = topology.bends[..];
            state.hinges[..] = topology.hinges[..];
            state.staged_hinges[..] = topology.hinges[..];
            state.corners[..] = material_plan.corners[..];
            state.triangle_uvs[..] = material_plan.triangle_uvs[..];
            state.material_particles[..] = material_plan.material_particles[..];
            state.material_normal_domains[..] = material_plan.material_normal_domains[..];
            state.material_ref_faces[..] = material_plan.material_ref_faces[..];
            if (desc.tangent_frame) {
                state.tangent_signs[..] = material_plan.tangent_signs[..];
                state.rest_tangents[..] = material_plan.rest_tangents[..];
                state.committed_tangents[..] = material_plan.initial_tangents[..];
                state.local_tangents[..] = material_plan.initial_tangents[..];
            }
            if (desc.collisions.self_collision) build_self_topology(state);

            Node* out_node = scene.add_node(parent: owner, name: "crowd_cloth_output")!;
            out_node.visible = false;
            out_node.visible_effective = false;
            out_node.layers = batch_node.layers;
            out_node.world = owner.world;
            scene.add(out_node, (ClothOutput){
                .owner = owner.id,
                .crowd = true,
                .part  = part_rec.part,
            });
            scene.add(out_node, (scene::Mesh){
                .geometry             = copy,
                .material             = batch.material,
                .cast_shadow          = batch.cast_shadow,
                .receive_shadow       = batch.receive_shadow,
                .trace                = batch.trace,
                .vertex_motion        = true,
                .vertex_history_token = 1,
            });
            state.output_node = out_node.id;
            part_rec.outputs[slot] = out_node.id;
        }

        part_rec.capacity = capacity;
        for (uint slot = 0; slot < crowd.count; slot++) {
            ClothState* state = part_rec.states[slot];
            Node* out_node = scene.node(part_rec.outputs[slot]);
            seed_crowd_slot_state(
                assets:   assets,
                owner:    owner,
                crowd:    crowd,
                part_rec: part_rec,
                state:    state,
                slot:     slot,
            )!;
            initial_cloth_publication(world, state, owner.world, true)!;

            uint gen = crowd.playback.slots[slot].generation;
            part_rec.slot_generations[slot] = gen;
            part_rec.published_colors[slot] = crowd.colors[slot];
            ClothOutput* marker = scene.get(out_node, ClothOutput);
            marker.instance = { .index = slot, .generation = gen };
            out_node.visible = true;
            out_node.visible_effective = owner.visible_effective;
        }

        part_rec.playback_identity = crowd.playback;
        part_rec.original_batch = crowd_part.batch;
        part_rec.original_visible = batch_node.visible;
        part_rec.material = batch.material;
        part_rec.cast_shadow = batch.cast_shadow;
        part_rec.receive_shadow = batch.receive_shadow;
        part_rec.trace = batch.trace;
        batch_node.visible = false;
        batch_node.visible_effective = false;
        part_rec.prepared = true;
    };
}

fn void? sample_crowd_slot_reference(
    AssetStore* assets,
    Node* owner,
    AnimatedCrowd* crowd,
    CrowdClothPart* part_rec,
    ClothState* state,
    uint slot,
    Vec3[] out_reference,
) @local {
    foreach (value : owner.world.m) {
        if (!math::is_finite(value)) return REFERENCE_UNAVAILABLE~;
    }
    if (slot >= crowd.count || crowd.count > part_rec.capacity) return REFERENCE_UNAVAILABLE~;
    if (!assets.geometries.is_live(part_rec.source)) return REFERENCE_UNAVAILABLE~;

    GeometryAsset* source = assets.geometry(part_rec.source);
    if (source.header.revision != part_rec.source_revision) return REFERENCE_UNAVAILABLE~;

    if (part_rec.skinned) {
        if (!assets.skeletons.is_live(part_rec.skeleton)) return REFERENCE_UNAVAILABLE~;
        SkeletonAsset* skel_record = assets.skeleton(part_rec.skeleton);
        if (skel_record.header.revision != part_rec.skeleton_revision) return REFERENCE_UNAVAILABLE~;
        if (crowd.joint_count != part_rec.joint_count) return REFERENCE_UNAVAILABLE~;
        if ((usz)(slot + 1) * part_rec.joint_count > crowd.palettes.len) return REFERENCE_UNAVAILABLE~;

        Mat4 instance_world = owner.world.mul(crowd.placements[slot].to_mat4());
        Mat4[] slot_palette = crowd.palettes[(usz)slot * part_rec.joint_count:part_rec.joint_count];
        foreach (joint_idx, mat : slot_palette) {
            foreach (entry : mat.m) {
                if (!math::is_finite(entry)) return REFERENCE_UNAVAILABLE~;
            }
            part_rec.palette_scratch[joint_idx] = bitcast(mat, SkinMat4);
        }
        if (catch anim::evaluate_skin_positions(
            output:  state.source_reference_scratch,
            source:  &source.data,
            palette: part_rec.palette_scratch,
            world:   instance_world,
        )) {
            return REFERENCE_UNAVAILABLE~;
        }
        foreach (particle, source_vertex : state.particle_sources) {
            out_reference[particle] = state.source_reference_scratch[source_vertex];
        }
        foreach (render_vertex, particle : state.render_to_particle) {
            if (state.source_reference_scratch[render_vertex] != out_reference[particle]) {
                return REFERENCE_UNAVAILABLE~;
            }
        }
        return;
    }

    Mat4 part_world = owner.world.mul(crowd.part_transform(slot, part_rec.part));
    if (catch evaluate_rigid_particles(part_world, state.rest, out_reference)) {
        return REFERENCE_UNAVAILABLE~;
    }
}

fn void update_slot_rest_constraints(ClothState* state, Mat4 slot_basis) @local {
    foreach (&edge : state.edges) {
        Vec3 p0 = maths::transform_point(slot_basis, state.rest[edge.first]);
        Vec3 p1 = maths::transform_point(slot_basis, state.rest[edge.second]);
        Vec3 delta = p1 - p0;
        float length = delta.length();
        edge.rest_length = length;
        edge.rest_direction = length > 0 ? delta / length : COLLAPSED_AXIS;
    }
    foreach (&bend : state.bends) {
        Vec3 p0 = maths::transform_point(slot_basis, state.rest[bend.first]);
        Vec3 p1 = maths::transform_point(slot_basis, state.rest[bend.second]);
        Vec3 delta = p1 - p0;
        float length = delta.length();
        bend.rest_length = length;
        bend.rest_direction = length > 0 ? delta / length : COLLAPSED_AXIS;
    }
}

fn void? seed_crowd_slot_state(
    AssetStore* assets,
    Node* owner,
    AnimatedCrowd* crowd,
    CrowdClothPart* part_rec,
    ClothState* state,
    uint slot,
) @local {
    sample_crowd_slot_reference(
        assets:        assets,
        owner:         owner,
        crowd:         crowd,
        part_rec:      part_rec,
        state:         state,
        slot:          slot,
        out_reference: state.current_reference,
    )!;

    Mat4 slot_basis = part_rec.skinned
        ? owner.world.mul(crowd.placements[slot].to_mat4())
        : owner.world.mul(crowd.part_transform(slot, part_rec.part));
    update_slot_rest_constraints(state, slot_basis);

    foreach (&hinge : state.hinges) {
        Vec3[4] world_pts = {
            state.current_reference[hinge.p0],
            state.current_reference[hinge.p1],
            state.current_reference[hinge.p2],
            state.current_reference[hinge.p3],
        };
        ClothHingeSample? sample = evaluate_hinge_sample(world_pts);
        if (catch sample) return c3d::INVALID_ARGUMENT~;
        hinge.last_angle = (float)sample.angle;
        hinge.lambda = 0;
    }
    state.staged_hinges[..] = state.hinges[..];

    state.solved_reference[..] = state.current_reference[..];
    state.published_reference[..] = state.current_reference[..];
    state.positions[..] = state.current_reference[..];
    state.predicted[..] = state.current_reference[..];
    state.published[..] = state.current_reference[..];
    state.velocities[..] = (Vec3){};
    state.accelerations[..] = (Vec3){};
    if (state.desc.collisions.continuous) {
        state.sweep_start[..] = state.current_reference[..];
        foreach (index, point : state.current_reference) {
            state.sweep_bounds[index] = { .min = point, .max = point };
        }
    }

    foreach (pin_slot, pin : state.pins) {
        state.pin_anchors[pin_slot] = state.current_reference[pin];
        state.pin_targets[pin_slot] = state.current_reference[pin];
    }
    foreach (soft_slot, attachment : state.soft_attachments) {
        state.soft_anchors[soft_slot] = state.current_reference[attachment.particle];
        state.soft_targets[soft_slot] = state.current_reference[attachment.particle];
        state.soft_lambdas[soft_slot] = {};
    }
    if (state.desc.tangent_frame) {
        foreach (v, rest_tangent : state.rest_tangents) {
            state.committed_tangents[v] = { rest_tangent.x, rest_tangent.y, rest_tangent.z, state.tangent_signs[v] };
            state.local_tangents[v] = state.committed_tangents[v];
        }
    }
    foreach (&body : state.bodies) {
        body.observed = false;
        body.published_observed = false;
    }

    Vec4 instance_color = crowd.colors[slot];
    foreach (vertex, base_color : part_rec.source_colors) {
        state.staged_colors[vertex] = base_color * instance_color;
    }
}

fn void deactivate_all_part_outputs(Scene* scene, CrowdClothPart* part_rec) @local {
    foreach (out_entity : part_rec.outputs) {
        deactivate_output_node(scene, out_entity);
    }
    if (part_rec.slot_generations.len) part_rec.slot_generations[..] = 0;
}

fn void? check_crowd_part_runtime(
    Scene* scene,
    AssetStore* assets,
    Node* owner,
    CrowdClothPart* part_rec,
    AnimatedCrowd** out_crowd,
    Node** out_batch_node,
) @local {
    if (node_in_lod_group(scene, owner)) return OWNERSHIP_CHANGED~;
    AnimatedCrowd* crowd = scene.get(owner, AnimatedCrowd);
    if (!crowd || !crowd.is_prepared()) return OWNERSHIP_CHANGED~;
    if (crowd.playback != part_rec.playback_identity) return OWNERSHIP_CHANGED~;
    if (crowd.placements.len != part_rec.capacity || crowd.count > part_rec.capacity
        || crowd.colors.len < part_rec.capacity) {
        return OWNERSHIP_CHANGED~;
    }
    if (!c3d::same_id(crowd.model, part_rec.model)) return OWNERSHIP_CHANGED~;
    if (part_rec.part >= crowd.parts.len) return OWNERSHIP_CHANGED~;

    CrowdPart* crowd_part = &crowd.parts[part_rec.part];
    if (!c3d::same_id(crowd_part.batch, part_rec.original_batch)
        || !scene.world.is_alive(part_rec.original_batch)) {
        return OWNERSHIP_CHANGED~;
    }
    Node* batch_node = scene.node(part_rec.original_batch);
    if (batch_node.parent != owner || batch_node.visible) return OWNERSHIP_CHANGED~;
    InstancedMesh* batch = scene.get(batch_node, InstancedMesh);
    if (!batch || !c3d::same_id(batch.geometry, part_rec.source) || !c3d::same_id(batch.material, part_rec.material)
        || batch.sway.amplitude != 0 || batch.fade.end != 0) {
        return OWNERSHIP_CHANGED~;
    }

    if (!assets.models.is_live(part_rec.model)
        || assets.model(part_rec.model).header.revision != part_rec.model_revision) {
        return REFERENCE_UNAVAILABLE~;
    }
    if (!assets.geometries.is_live(part_rec.source)
        || assets.geometry(part_rec.source).header.revision != part_rec.source_revision) {
        return REFERENCE_UNAVAILABLE~;
    }
    if (part_rec.skinned) {
        if (!assets.skeletons.is_live(part_rec.skeleton)
            || assets.skeleton(part_rec.skeleton).header.revision != part_rec.skeleton_revision
            || crowd.joint_count != part_rec.joint_count) {
            return REFERENCE_UNAVAILABLE~;
        }
    }
    if (catch check_cloth_material(assets, batch.material, true)) {
        return REFERENCE_UNAVAILABLE~;
    }

    *out_crowd = crowd;
    *out_batch_node = batch_node;
}

fn void? check_crowd_slot_output(
    Scene* scene,
    AssetStore* assets,
    Node* owner,
    CrowdClothPart* part_rec,
    ClothState* state,
    uint slot,
    Node** out_node,
    scene::Mesh** out_mesh,
) @local {
    Entity out_entity = part_rec.outputs[slot];
    if (!out_entity.generation || !scene.world.is_alive(out_entity)) return OWNERSHIP_CHANGED~;
    Node* node = scene.node(out_entity);
    if (node.parent != owner
        || node.transform_space != TransformSpace.PARENT
        || node.local.position != (Vec3){}
        || node.local.rotation.v != maths::TRANSFORM_IDENTITY.rotation.v
        || node.local.scale != (Vec3){ 1, 1, 1 }) {
        deactivate_output_node(scene, out_entity);
        return OWNERSHIP_CHANGED~;
    }
    ClothOutput* marker = scene.get(node, ClothOutput);
    scene::Mesh* mesh = scene.get(node, scene::Mesh);
    if (!marker || !c3d::same_id(marker.owner, owner.id) || !marker.crowd || marker.part != part_rec.part
        || !mesh || !c3d::same_id(mesh.geometry, state.geometry) || scene.has(node, SkinBinding)) {
        deactivate_output_node(scene, out_entity);
        return OWNERSHIP_CHANGED~;
    }
    if (!assets.geometries.is_live(state.geometry)) {
        deactivate_output_node(scene, out_entity);
        return OWNERSHIP_CHANGED~;
    }
    *out_node = node;
    *out_mesh = mesh;
}

fn void update_crowd_cloths(PhysicsWorld* world, uint steps) @private {
    Scene* scene = world.scene;
    AssetStore* assets = world.assets;

    scene.@each(CrowdCloth; Entity owner_entity, CrowdCloth* component) {
        if (component.state) {
            Node* owner = scene.node(owner_entity);
            foreach (&part_rec : component.state.parts) {
                if (!part_rec.prepared || !part_rec.states.len) {
                    world.cloth_stats.pending++;
                    continue;
                }

                AnimatedCrowd* crowd;
                Node* batch_node;
                if (catch excuse = check_crowd_part_runtime(scene, assets, owner, part_rec, &crowd, &batch_node)) {
                    deactivate_all_part_outputs(scene, part_rec);
                    ClothContactStage stage = excuse == REFERENCE_UNAVAILABLE
                        ? ClothContactStage.REFERENCE
                        : ClothContactStage.PUBLICATION;
                    part_rec.states[0].contact_result = {
                        .failure = excuse,
                        .stage   = stage,
                    };
                    world.cloth_stats.failed++;
                    continue;
                }

                // Reconcile inactive and replaced slots before any numerical work.
                for (uint slot = crowd.count; slot < part_rec.capacity; slot++) {
                    deactivate_output_node(scene, part_rec.outputs[slot]);
                    part_rec.slot_generations[slot] = 0;
                }
                for (uint slot = 0; slot < crowd.count; slot++) {
                    uint live_gen = crowd.playback.slots[slot].generation;
                    if (live_gen != part_rec.slot_generations[slot]) {
                        deactivate_output_node(scene, part_rec.outputs[slot]);
                    }
                }

                for (uint slot = 0; slot < crowd.count; slot++) {
                    ClothState* state = part_rec.states[slot];
                    uint live_gen = crowd.playback.slots[slot].generation;
                    bool reseeded = live_gen != part_rec.slot_generations[slot];

                    Node* out_node;
                    scene::Mesh* out_mesh;
                    if (catch excuse = check_crowd_slot_output(
                        scene:    scene,
                        assets:   assets,
                        owner:    owner,
                        part_rec: part_rec,
                        state:    state,
                        slot:     slot,
                        out_node: &out_node,
                        out_mesh: &out_mesh,
                    )) {
                        part_rec.slot_generations[slot] = 0;
                        state.contact_result = {
                            .failure = excuse,
                            .stage   = ClothContactStage.PUBLICATION,
                        };
                        world.cloth_stats.failed++;
                        continue;
                    }

                    time::Clock started = clock::now();
                    double publication_seconds;
                    if (catch excuse = update_crowd_slot(
                        world:               world,
                        owner:               owner,
                        batch_node:          batch_node,
                        crowd:               crowd,
                        part_rec:            part_rec,
                        state:               state,
                        out_node:            out_node,
                        out_mesh:            out_mesh,
                        slot:                slot,
                        live_gen:            live_gen,
                        steps:               steps,
                        reseeded:            reseeded,
                        publication_seconds: &publication_seconds,
                    )) {
                        state.contact_result.failure = excuse;
                        if (!reseeded && excuse != OWNERSHIP_CHANGED) {
                            time::Clock reexpression_start = clock::now();
                            if (catch reexpression_failure = reexpress_cloth(state, owner.world)) {
                                state.contact_result.failure = reexpression_failure;
                                state.contact_result.stage = ClothContactStage.REEXPRESSION;
                            }
                            publication_seconds += (clock::now() - reexpression_start).to_sec();
                        }
                        world.cloth_stats.failed++;
                    }

                    double total_seconds = (clock::now() - started).to_sec();
                    world.cloth_stats.solve_seconds += math::max(0.0, total_seconds - publication_seconds);
                    world.cloth_stats.publish_seconds += publication_seconds;
                    world.cloth_stats.candidates += state.contact_result.candidates;
                    world.cloth_stats.contacts += state.contact_result.contacts;
                    world.cloth_stats.ccd_iterations += state.contact_result.ccd_iterations;
                    world.cloth_stats.impacts += state.contact_result.impacts;
                    world.cloth_stats.max_residual = math::max(
                        world.cloth_stats.max_residual,
                        state.contact_result.max_residual,
                    );
                    world.cloth_stats.particles += (uint)state.positions.len;
                    world.cloth_stats.constraints += (uint)(
                        state.edges.len + state.bends.len + state.hinges.len + state.soft_attachments.len
                    );
                }
            }
        }
    };
}

fn void? update_crowd_slot(
    PhysicsWorld* world,
    Node* owner,
    Node* batch_node,
    AnimatedCrowd* crowd,
    CrowdClothPart* part_rec,
    ClothState* state,
    Node* out_node,
    scene::Mesh* out_mesh,
    uint slot,
    uint live_gen,
    uint steps,
    bool reseeded,
    double* publication_seconds,
) @local {
    Scene* scene = world.scene;
    AssetStore* assets = world.assets;
    out_node.layers = batch_node.layers;

    if (reseeded) {
        state.contact_result = {};
        state.contact_result.stage = ClothContactStage.REFERENCE;
        if (catch seed_crowd_slot_state(
            assets:   assets,
            owner:    owner,
            crowd:    crowd,
            part_rec: part_rec,
            state:    state,
            slot:     slot,
        )) {
            part_rec.slot_generations[slot] = 0;
            return REFERENCE_UNAVAILABLE~;
        }
        state.contact_result.stage = ClothContactStage.PUBLICATION;
        out_mesh.reset_vertex_history()!;
    }

    ClothState staged = staged_cloth(state);
    defer {
        state.contact_result = staged.contact_result;
        state.path_count = staged.path_count;
    }

    staged.contact_result.stage = ClothContactStage.ARITHMETIC;
    if (!physics::contact_arithmetic_supported()) return CONTACT_PRECISION_EXCEEDED~;

    staged.contact_result.stage = ClothContactStage.REFERENCE;
    if (!reseeded) {
        sample_crowd_slot_reference(
            assets:        assets,
            owner:         owner,
            crowd:         crowd,
            part_rec:      part_rec,
            state:         &staged,
            slot:          slot,
            out_reference: staged.current_reference,
        )!;
    }

    bool colors_changed = reseeded || crowd.colors[slot] != part_rec.published_colors[slot];
    if (colors_changed && !reseeded) {
        Vec4 instance_color = crowd.colors[slot];
        foreach (vertex, base_color : part_rec.source_colors) {
            state.staged_colors[vertex] = base_color * instance_color;
        }
    }

    staged.contact_result.stage = ClothContactStage.BINDINGS;
    refresh_colliders(world, &staged)!;
    foreach (pin_slot, pin : staged.pins) {
        staged.pin_anchors[pin_slot] = staged.solved_reference[pin];
        staged.pin_targets[pin_slot] = staged.current_reference[pin];
    }
    foreach (soft_slot, attachment : staged.soft_attachments) {
        staged.soft_anchors[soft_slot] = staged.solved_reference[attachment.particle];
        staged.soft_targets[soft_slot] = staged.current_reference[attachment.particle];
    }
    sample_bodies(scene, &staged);

    if (steps) {
        if (staged.desc.substeps > uint::max / steps) return c3d::CAPACITY_EXCEEDED~;
        solve_cloth(
            world:   world,
            state:   &staged,
            wind:    scene.get(owner, Wind),
            gravity: world.desc.tuning.gravity,
            step_dt: world.desc.tuning.fixed_dt,
            steps:   steps,
        )!;
    }

    time::Clock publication_start = clock::now();
    defer *publication_seconds += (clock::now() - publication_start).to_sec();
    prepare_publication(world, &staged, steps != 0)!;

    staged.contact_result.stage = ClothContactStage.PUBLICATION;
    bool changed = stage_local_positions(&staged, owner.world, reseeded)!;
    if (contact_pass(world: world, state: &staged, positions: staged.publication_roundtrip, apply: false)! != 0) {
        staged.contact_result.stage = ClothContactStage.PUBLICATION;
        return CONTACT_PRECISION_EXCEEDED~;
    }

    staged.contact_result.stage = ClothContactStage.MATERIAL;
    stage_material_frames(&staged, changed)!;

    commit_cloth(state, &staged);
    state.local_bounds = staged.local_bounds;
    commit_local_publication(state, owner.world, changed, colors_changed);

    if (reseeded) {
        part_rec.slot_generations[slot] = live_gen;
        ClothOutput* marker = scene.get(out_node, ClothOutput);
        marker.instance = { .index = slot, .generation = live_gen };
        out_node.visible = true;
    }
    if (colors_changed) {
        part_rec.published_colors[slot] = crowd.colors[slot];
    }
    out_node.world = owner.world;
    out_node.visible_effective = owner.visible_effective && out_node.visible;
    staged.contact_result.stage = ClothContactStage.NONE;
}
