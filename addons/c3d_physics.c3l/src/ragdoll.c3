module c3d::physics;

import std::math;
import std::math::quaternion;
import c3d;
import c3d::anim;
import c3d::asset;
import c3d::ecs;
import c3d::maths;
import c3d::scene;
import b3;

const float MIN_BONE_LENGTH @local = 0.0001f; // meters; a shorter child offset makes the bone a leaf
const float SCALE_TOLERANCE @local = 0.0001f;
const float ANTIPARALLEL_LENGTH @local = 0.000001f;
const float AXIS_REFERENCE_LIMIT @local = 0.9f; // a from-vector this close to X takes Y as its cross reference
const float MIN_FACING_LENGTH @local = 0.3f; // a flattened facing shorter than this is a pitch-only fall: yaw kept

<*
 Who drives the bone bodies.
*>
enum RagdollMode {
    ANIMATED,     // kinematic bones follow the joint nodes
    SIMULATED,    // dynamic bones drive the joint nodes at weight
}

<*
 Capsule and joint of one skeleton bone; the bone runs from its joint to its child joint.
*>
struct RagdollBone {
    uint       joint;
    float      radius;
    float      density;
    float      length;       // 0 measures to the child joint; leaf bones need a value
    JointKind  kind;         // SPHERICAL or REVOLUTE, toward the parent bone
    Vec3       hinge_axis;   // REVOLUTE, in the joint's bind-pose space
    JointLimit cone;         // SPHERICAL; upper is the half angle
    JointLimit twist;        // SPHERICAL
    JointLimit angle;        // REVOLUTE
}

<*
 Bones of a ragdoll, parents before children, and how they collide.
*>
struct RagdollDesc {
    RagdollBone[]   bones;
    CollisionFilter filter;
    bool            collide_adjacent;
}

<*
 Ragdoll on a skin node; bone nodes are its children.
*>
struct Ragdoll {
    Node*[]            bone_nodes;
    uint[]             bone_joints;
    maths::Transform[] joint_in_bone;      // joint frame in bone body space, from the bind pose
    int[]              joint_bone;         // per skeleton joint: bone index, -1 without a bone
    int[]              parents;            // copied, so the ragdoll outlives edits to the skeleton asset
    uint[]             joint_order;        // skeleton joints, parents first
    maths::Transform[] frozen;             // joint locals captured by recover_ragdoll
    Mat4[]             joint_worlds;       // scratch for update_ragdolls and recover_ragdoll
    Quat               hips_bind_rotation; // root bone rotation in skin-node space
    float              weight;             // 0 animated pose, 1 ragdoll pose
    RagdollMode        mode;
}

<*
 Author bone nodes, bodies and joints for the skin on the node.
 @param [&in] assets : "Supplies the skeleton."
 @param [&in] skin_node : "Carries a SkinBinding; world matrix current, unit scale."
 @return? NO_SKIN, RAGDOLL_EXISTS, c3d::INVALID_ARGUMENT, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
 @require self.world.is_registered(Ragdoll)
*>
fn void? Scene.build_ragdoll(
    &self,
    AssetStore* assets,
    Node* skin_node,
    RagdollDesc desc,
) {
    if (!self.has(skin_node, SkinBinding)) return NO_SKIN~;
    if (self.has(skin_node, Ragdoll)) return RAGDOLL_EXISTS~;
    Vec3 scale_error = maths::transform_from_mat4(skin_node.world).scale - (Vec3){ 1, 1, 1 };
    if (math::max(math::abs(scale_error.x), math::abs(scale_error.y), math::abs(scale_error.z)) > SCALE_TOLERANCE) {
        return c3d::UNSUPPORTED~;
    }
    Skeleton* skeleton = &assets.skeleton(self.get(skin_node, SkinBinding).skeleton).data;
    RagdollBone[] bones = desc.bones;
    usz joint_count = skeleton.parents.len;
    if (bones.len == 0) return c3d::INVALID_ARGUMENT~;

    Ragdoll ragdoll = carve_ragdoll_block(self.allocator, bones.len, joint_count);
    defer catch alloc::free(self.allocator, ragdoll.bone_nodes.ptr);
    usz created;
    defer catch {
        foreach (node : ragdoll.bone_nodes[:created]) self.remove(node);
    }

    @pool() {
        int[] parent_bone = alloc::new_array(tmem, int, bones.len);
        maths::Transform[] bind = alloc::new_array(tmem, maths::Transform, bones.len);
        Vec3[] axes = alloc::new_array(tmem, Vec3, bones.len);
        maths::Transform[] locals = alloc::new_array(tmem, maths::Transform, bones.len);
        float[] lengths = alloc::new_array(tmem, float, bones.len);
        index_bones(&ragdoll, skeleton, bones)!;
        foreach (usz index, &bone : bones) {
            parent_bone[index] = parent_bone_of(&ragdoll, bone.joint, index)!;
            bind[index] = maths::transform_from_mat4(maths::inverse_affine(skeleton.inverse_bind[bone.joint]));
        }
        foreach (usz index, &bone : bones) {
            int parent = parent_bone[index];
            Vec3 fallback = parent < 0 ? (Vec3){ 0, 1, 0 } : axes[parent];
            Vec3 offset;
            if (try child = child_position(skeleton, bones, parent_bone, index)) offset = child - bind[index].position;
            float distance = offset.length();
            if (distance > MIN_BONE_LENGTH) {
                axes[index] = offset / distance;
            } else {
                if (bone.length == 0) return c3d::INVALID_ARGUMENT~;
                axes[index] = fallback;
            }
            lengths[index] = bone.length != 0 ? bone.length : distance;
            locals[index] = {
                .position = bind[index].position + axes[index] * (lengths[index] / 2),
                .rotation = rotation_from_to({ 0, 1, 0 }, axes[index]),
                .scale    = { 1, 1, 1 },
            };
            ragdoll.joint_in_bone[index] = relative(locals[index].to_mat4(), bind[index].to_mat4());
        }

        foreach (usz index, &bone : bones) {
            Node* node = self.add_node(skin_node, skeleton.joint_names[bone.joint])!;
            ragdoll.bone_nodes[index] = node;
            created++;
            node.local = locals[index];
            ColliderDesc collider = default_collider_desc(CAPSULE);
            collider.radius = bone.radius;
            collider.half_height = math::max(lengths[index] / 2 - bone.radius, 0.0f);
            collider.density = bone.density;
            collider.filter = desc.filter;
            BodyDesc body = default_body_desc(KINEMATIC);
            body.name = node.name;
            self.add(node, copy_physics_body(self.allocator, body, (&collider)[:1]));

            int parent = parent_bone[index];
            if (parent < 0) continue;
            Vec3 frame_axis = axes[index];
            if (bone.kind == REVOLUTE) frame_axis = bind[index].rotation.rotate_vec3(bone.hinge_axis).normalize();
            Mat4 frame_skin = (maths::Transform){
                .position = bind[index].position,
                .rotation = rotation_from_to({ 0, 0, 1 }, frame_axis),
                .scale    = { 1, 1, 1 },
            }.to_mat4();
            JointDesc joint = default_joint_desc(bone.kind, ragdoll.bone_nodes[parent].id);
            joint.anchor_frame = relative(locals[parent].to_mat4(), frame_skin);
            joint.frame = relative(locals[index].to_mat4(), frame_skin);
            joint.collide_connected = desc.collide_adjacent;
            if (bone.kind == REVOLUTE) {
                joint.revolute.angle = bone.angle;
            } else {
                joint.spherical.enable_cone = bone.cone.enabled;
                joint.spherical.cone_angle = bone.cone.upper;
                joint.spherical.twist = bone.twist;
            }
            self.add(node, (PhysicsJoint){ .desc = joint, .status = PENDING });
        }
        ragdoll.hips_bind_rotation = locals[0].rotation;
    };

    order_joints(&ragdoll);
    self.add(skin_node, ragdoll);
}

<*
 Remove the bone nodes and the component.
 Invalidates Ragdoll pointers.
 @param [&in] skin_node : "Carries the ragdoll."
 @require self.has(skin_node, Ragdoll)
*>
fn void Scene.remove_ragdoll(&self, Node* skin_node) {
    foreach (node : self.get(skin_node, Ragdoll).bone_nodes) self.remove(node);
    self.remove_component(skin_node, Ragdoll);
}

<*
 Switch bone bodies between kinematic and dynamic in place; velocities are kept.
 @param [&in] skin_node : "Carries the ragdoll."
 @require self.scene.has(skin_node, Ragdoll)
*>
fn void PhysicsWorld.set_ragdoll_mode(&self, Node* skin_node, RagdollMode mode) {
    Scene* scene = self.scene;
    Ragdoll* ragdoll = scene.get(skin_node, Ragdoll);
    BodyKind kind = mode == SIMULATED ? DYNAMIC : KINEMATIC;
    foreach (node : ragdoll.bone_nodes) {
        scene.get(node, PhysicsBody).body.kind = kind;
        if (!scene.has(node, RigidBody)) continue;
        RigidBody* body = scene.get(node, RigidBody);
        body.kind = kind;
        body.body.set_type(body_type(kind));
    }
    ragdoll.mode = mode;
}

<*
 Stand the character where the hips lie and freeze the pose for blending out.
 Calls update_world.
 @param [&in] skin_node : "Carries the ragdoll."
 @param [&inout] character : "Ancestor of the skin node and its joint nodes; yawed with the hips."
 @require self.scene.has(skin_node, Ragdoll)
*>
fn void PhysicsWorld.recover_ragdoll(&self, Node* skin_node, Node* character) {
    Scene* scene = self.scene;
    Ragdoll* ragdoll = scene.get(skin_node, Ragdoll);
    Node*[] joints = scene.get(skin_node, SkinBinding).joints;
    float alpha = self.desc.tuning.interpolate ? self.alpha : 1;

    foreach (joint : ragdoll.joint_order) {
        Mat4 animated = parent_world_of(ragdoll, joints, joint).mul(joints[joint].local.to_mat4());
        ragdoll.joint_worlds[joint] = joint_target_world(scene, ragdoll, joint, alpha) ?? animated;
    }

    Node* hips_node = ragdoll.bone_nodes[0];
    if (scene.has(hips_node, RigidBody)) {
        RigidBody* hips = scene.get(hips_node, RigidBody);
        maths::Transform hips_pose = interpolate_pose(hips.previous, hips.current, alpha);
        Quat standing = maths::transform_from_mat4(skin_node.world).rotation.mul(ragdoll.hips_bind_rotation);
        Vec3 facing = hips_pose.rotation.mul(standing.conjugate()).rotate_vec3({ 0, 0, 1 });
        facing.y = 0;
        maths::Transform pose = maths::transform_from_mat4(character.world);
        pose.position.x = hips_pose.position.x;
        pose.position.z = hips_pose.position.z;
        if (facing.length() > MIN_FACING_LENGTH) {
            Quat yaw = quaternion::from_axis_angle{float}({ 0, 1, 0 }, math::atan2(facing.x, facing.z));
            pose.rotation = yaw.mul(pose.rotation).normalize();
        }
        write_pose(scene, character, pose);
    }
    scene.update_world();

    foreach (joint : ragdoll.joint_order) {
        ragdoll.frozen[joint] = relative(parent_world_of(ragdoll, joints, joint), ragdoll.joint_worlds[joint]);
    }
    self.set_ragdoll_mode(skin_node, ANIMATED);
}

<*
 Blend ragdoll poses into joint nodes at each weight; call after update.
 While blending out, colliders follow the animated pose, not the blended one.
*>
fn void PhysicsWorld.update_ragdolls(&self) {
    Scene* scene = self.scene;
    float alpha = self.desc.tuning.interpolate ? self.alpha : 1;
    scene.@each(Ragdoll; entity, ragdoll) {
        if (ragdoll.weight > 0) blend_ragdoll(scene, scene.node(entity), ragdoll, alpha);
    };
}

<*
 Bone of the joint: spherical, water density, no limits; radius left to fill.
*>
fn RagdollBone default_ragdoll_bone(uint joint) {
    return { .joint = joint, .density = DEFAULT_DENSITY, .kind = SPHERICAL };
}

<*
 Ragdoll colliding with every category; adjacent bones do not collide.
*>
fn RagdollDesc default_ragdoll_desc() {
    return { .filter = FILTER_ALL };
}

fn void drive_ragdolls(PhysicsWorld* world) @private {
    Scene* scene = world.scene;
    scene.@each(Ragdoll; entity, ragdoll) {
        if (ragdoll.mode == ANIMATED) {
            Node* skin_node = scene.node(entity);
            Node*[] joints = scene.get(skin_node, SkinBinding).joints;
            Mat4 inverse_skin = maths::inverse_affine(skin_node.world);
            foreach (index, node : ragdoll.bone_nodes) {
                Mat4 bone_in_joint = maths::inverse_affine(ragdoll.joint_in_bone[index].to_mat4());
                node.world = joints[ragdoll.bone_joints[index]].world.mul(bone_in_joint);
                node.local = maths::transform_from_mat4(inverse_skin.mul(node.world));
            }
        }
    };
}

fn void blend_ragdoll(
    Scene* scene,
    Node* skin_node,
    Ragdoll* ragdoll,
    float alpha,
) @local {
    Node*[] joints = scene.get(skin_node, SkinBinding).joints;
    float weight = math::min(ragdoll.weight, 1.0f);
    foreach (joint : ragdoll.joint_order) {
        Node* node = joints[joint];
        Mat4 parent_world = parent_world_of(ragdoll, joints, joint);
        maths::Transform target = node.local;
        switch (ragdoll.mode) {
            case ANIMATED:
                target = ragdoll.frozen[joint];
            case SIMULATED:
                if (try world = joint_target_world(scene, ragdoll, joint, alpha)) {
                    target = relative(parent_world, world);
                }
        }
        if (node.local.rotation.v.dot(target.rotation.v) < 0) target.rotation = { .v = -target.rotation.v };
        node.local.position += (target.position - node.local.position) * weight;
        node.local.rotation = node.local.rotation.nlerp(target.rotation, weight);
        ragdoll.joint_worlds[joint] = parent_world.mul(node.local.to_mat4());
    }
}

// A root joint's parent is a scene node; the others were written earlier in joint_order.
fn Mat4 parent_world_of(Ragdoll* ragdoll, Node*[] joints, uint joint) @local {
    int parent = ragdoll.parents[joint];
    return parent < 0 ? joints[joint].parent.world : ragdoll.joint_worlds[parent];
}

// Faults when the joint has no bone or its body is not built yet.
fn Mat4? joint_target_world(
    Scene* scene,
    Ragdoll* ragdoll,
    uint joint,
    float alpha,
) @local {
    int bone = ragdoll.joint_bone[joint];
    if (bone < 0) return NO_BODY~;
    Node* node = ragdoll.bone_nodes[bone];
    if (!scene.has(node, RigidBody)) return NO_BODY~;
    RigidBody* body = scene.get(node, RigidBody);
    return interpolate_pose(body.previous, body.current, alpha).to_mat4().mul(ragdoll.joint_in_bone[bone].to_mat4());
}

fn void? index_bones(Ragdoll* ragdoll, Skeleton* skeleton, RagdollBone[] bones) @local {
    ragdoll.joint_bone[..] = -1;
    ragdoll.parents[..] = skeleton.parents[..];
    foreach (usz index, &bone : bones) {
        if (bone.joint >= skeleton.parents.len) return c3d::INVALID_ARGUMENT~;
        if (ragdoll.joint_bone[bone.joint] >= 0) return c3d::INVALID_ARGUMENT~;
        switch (bone.kind) {
            case SPHERICAL:
                break;
            case REVOLUTE:
                if (bone.hinge_axis.length() < MIN_BONE_LENGTH) return c3d::INVALID_ARGUMENT~;
            case DISTANCE:
            case PRISMATIC:
            case WELD:
            case WHEEL:
            case MOTOR:
            case PARALLEL:
            case FILTER:
                return c3d::INVALID_ARGUMENT~;
        }
        ragdoll.joint_bone[bone.joint] = (int)index;
        ragdoll.bone_joints[index] = bone.joint;
    }
}

// The bone of the nearest listed ancestor joint; a parent listed after the child faults.
fn int? parent_bone_of(Ragdoll* ragdoll, uint joint, usz index) @local {
    for (int ancestor = ragdoll.parents[joint]; ancestor >= 0; ancestor = ragdoll.parents[ancestor]) {
        int bone = ragdoll.joint_bone[ancestor];
        if (bone < 0) continue;
        if ((usz)bone > index) return c3d::INVALID_ARGUMENT~;
        return bone;
    }
    return -1;
}

// The first listed child bone wins over skeleton order, so branching joints point along the ragdoll.
fn Vec3? child_position(
    Skeleton* skeleton,
    RagdollBone[] bones,
    int[] parent_bone,
    usz index,
) @local {
    foreach (child, parent : parent_bone) {
        if (parent == (int)index) return bind_position(skeleton, bones[child].joint);
    }
    foreach (child, parent : skeleton.parents) {
        if (parent == (int)bones[index].joint) return bind_position(skeleton, (uint)child);
    }
    return NOT_FOUND~;
}

fn Vec3 bind_position(Skeleton* skeleton, uint joint) @local {
    return maths::translation(maths::inverse_affine(skeleton.inverse_bind[joint]));
}

fn void order_joints(Ragdoll* ragdoll) @local {
    usz count;
    @pool() {
        bool[] placed = alloc::new_array(tmem, bool, ragdoll.parents.len);
        uint[] chain = alloc::new_array(tmem, uint, ragdoll.parents.len);
        foreach (joint, parent : ragdoll.parents) {
            usz length;
            for (int walk = (int)joint; walk >= 0 && !placed[walk]; walk = ragdoll.parents[walk]) {
                chain[length++] = (uint)walk;
            }
            while (length > 0) {
                uint next = chain[--length];
                placed[next] = true;
                ragdoll.joint_order[count++] = next;
            }
        }
    };
}

fn Ragdoll carve_ragdoll_block(Allocator allocator, usz bone_count, usz joint_count) @local {
    BlockCursor measure;
    carve_ragdoll(&measure, bone_count, joint_count);
    BlockCursor fill = { .base = alloc::malloc(allocator, (sz)measure.offset) };
    return carve_ragdoll(&fill, bone_count, joint_count);
}

// The bone node array comes first, so its pointer is the block base the removal hook frees.
fn Ragdoll carve_ragdoll(BlockCursor* cursor, usz bone_count, usz joint_count) @local {
    return {
        .bone_nodes    = carve(cursor, Node*, bone_count),
        .bone_joints   = carve(cursor, uint, bone_count),
        .joint_in_bone = carve(cursor, maths::Transform, bone_count),
        .joint_bone    = carve(cursor, int, joint_count),
        .parents       = carve(cursor, int, joint_count),
        .joint_order   = carve(cursor, uint, joint_count),
        .frozen        = carve(cursor, maths::Transform, joint_count),
        .joint_worlds  = carve(cursor, Mat4, joint_count),
    };
}

fn void free_ragdoll(Entity entity, void* component, void* user) @private {
    Ragdoll* ragdoll = component;
    alloc::free(*(Allocator*)user, ragdoll.bone_nodes.ptr);
}

fn maths::Transform relative(Mat4 parent_world, Mat4 world) @local {
    return maths::transform_from_mat4(maths::inverse_affine(parent_world).mul(world));
}

fn Quat rotation_from_to(Vec3 from, Vec3 to) @local {
    Vec3 half = from + to;
    if (half.length() < ANTIPARALLEL_LENGTH) {
        Vec3 reference = math::abs(from.x) < AXIS_REFERENCE_LIMIT ? (Vec3){ 1, 0, 0 } : (Vec3){ 0, 1, 0 };
        return quaternion::from_axis_angle{float}(from.cross(reference).normalize(), (float)math::PI);
    }
    half = half.normalize();
    Vec3 axis = from.cross(half);
    return { axis.x, axis.y, axis.z, from.dot(half) };
}
