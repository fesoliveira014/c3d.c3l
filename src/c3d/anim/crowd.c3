module c3d::anim;

import c3d;
import c3d::asset;
import c3d::scene;
import std::math;

<*
 Evaluate prepared crowds and publish palettes, morph weights and batches.
 @param [&in] assets : "Holds every crowd's model, skeleton and clips."
 @param [&inout] scene : "Pending crowds remain unchanged."
 @param dt : "Finite nonnegative seconds."
 @require math::is_finite(dt) && dt >= 0
*>
fn void crowd_update(AssetStore* assets, Scene* scene, float dt) {
    scene.@each(AnimatedCrowd; Entity entity, AnimatedCrowd* crowd) {
        if (crowd.is_prepared()) {
            crowd.playback.update(assets, dt);
            publish_crowd_pose(assets, scene, crowd);
        }
    };
}

<*
 Publish evaluated crowd outputs without advancing playback.
 @param [&in] assets : "Resolves the model and its shared skin binding."
 @param [&inout] scene : "Publishes the owner's generated part batches."
 @param [&inout] crowd : "Contains the current evaluated node and morph outputs."
 @require crowd.is_prepared(), assets.models.is_live(crowd.model)
*>
fn void publish_crowd_pose(AssetStore* assets, Scene* scene, AnimatedCrowd* crowd) {
    CrowdPlaybackState* playback = crowd.playback;

    if (crowd.joint_count) {
        ModelTemplate* template = &assets.model(crowd.model).data;
        ModelSkin* skin = &template.skins[0];
        Skeleton* skeleton = &assets.skeleton(skin.skeleton).data;

        for (uint instance = 0; instance < crowd.count; instance++) {
            Transform[] locals = playback.poses[(usz)instance * playback.base_pose.len:playback.base_pose.len];
            foreach (usz index, local : locals) {
                Mat4 matrix = local.to_mat4();
                int parent = playback.parents[index];
                crowd.scratch_worlds[index] = parent < 0 ? matrix : crowd.scratch_worlds[parent].mul(matrix);
            }

            Mat4[] palette = crowd.palettes[(usz)instance * crowd.joint_count:crowd.joint_count];
            foreach (usz joint, node : skin.joint_nodes) {
                palette[joint] = crowd.scratch_worlds[node].mul(skeleton.inverse_bind[joint]);
            }
        }
    }

    scene.write_crowd_batches(crowd);
}

<*
 Compose one part's affine transform relative to its crowd owner.
 @param instance : "Live logical source slot."
 @param part : "Logical mesh in template order."
 @require self.is_prepared(), instance < self.count, part < self.parts.len
*>
fn Mat4 AnimatedCrowd.part_transform(&self, uint instance, uint part) {
    Mat4 placement = self.placements[instance].to_mat4();
    if (self.parts[part].skinned) return placement;

    CrowdPlaybackState* playback = self.playback;
    Transform[] locals = playback.poses[(usz)instance * playback.base_pose.len:playback.base_pose.len];
    uint mesh_node = self.parts[part].template_node;

    for (uint node = 0; node <= mesh_node; node++) {
        Mat4 local = locals[node].to_mat4();
        int parent = playback.parents[node];
        self.scratch_worlds[node] = parent < 0 ? local : self.scratch_worlds[parent].mul(local);
    }

    return placement.mul(self.scratch_worlds[mesh_node]);
}

<*
 Determine one part instance's local reflection parity.
 @require self.is_prepared(), instance < self.count, part < self.parts.len
*>
fn bool AnimatedCrowd.part_mirrored(&self, uint instance, uint part) {
    if (self.parts[part].skinned) return scene::transform_mirrored(self.placements[instance]);

    return self.part_transform(instance, part).determinant() < 0;
}

<*
 Count reflected instances of one logical part.
 @require self.is_prepared(), part < self.parts.len
*>
fn uint AnimatedCrowd.part_mirrored_count(&self, uint part) {
    uint count;
    for (uint instance = 0; instance < self.count; instance++) {
        if (self.part_mirrored(instance, part)) count++;
    }

    return count;
}

<*
 Apply each live instance's motion without replacing playback identities.
 @param [&inout] crowd : "Consume each update's output once."
 @require crowd.is_prepared()
*>
fn void Scene.apply_crowd_root_motion(&self, AnimatedCrowd* crowd) {
    foreach (usz index, &placement : crowd.placements[:crowd.count]) {
        RootMotionDelta delta = crowd.playback.slots[index].root_motion;
        placement.position += placement.rotation.rotate_vec3(placement.scale * delta.translation);
        placement.rotation = placement.rotation.mul(delta.rotation).normalize();
    }

    self.write_crowd_batches(crowd);
}
