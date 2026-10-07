module c3d::serial;

import c3d;
import c3d::anim::ik;
import c3d::asset;
import c3d::describe;
import c3d::scene;
import std::math;

const ulong SKIN_AUTHORING_LAYOUT @local = 0xbe949f9d428c68af;
const ulong IK_LIMIT_LAYOUT @local = 0x47036041dcad1aad;
const ulong IK_AUTHORING_LAYOUT @local = 0x070a8169e5189396;
const ulong FOOT_AUTHORING_LAYOUT @local = 0x4c935a49dedb121f;
const ulong LOOK_AUTHORING_LAYOUT @local = 0x009ec095d160ac5a;

<* Skeleton and required joints used by skin preflight. *>
struct SkinAuthoring {
    SkeletonId skeleton;
    NodeReference[] joints;
}

struct IkAuthoring @private {
    NodeReference[ik::TWO_BONE_JOINTS] joints;
    NodeReference target;
    NodeReference pole;
    float weight;
    IkLimit[ik::TWO_BONE_JOINTS] limits;
}

struct FootAuthoring @private {
    IkAuthoring leg;
    float foot_height;
    float lift_fade;
    float ray_height;
    float ray_length;
}

struct LookAuthoring @private {
    NodeReference[] joints;
    float[] weights;
    NodeReference target;
    Vec3 forward;
    float max_angle;
    float weight;
}

fn void? register_rig_codecs() @private {
    describe::register_reflected(SkinAuthoring)!;
    describe::register_reflected(IkLimit)!;
    describe::register_reflected(IkAuthoring)!;
    describe::register_reflected(FootAuthoring)!;
    describe::register_reflected(LookAuthoring)!;
    register_core_value(SkinAuthoring, SKIN_AUTHORING_LAYOUT, &defaults_skin)!;
    register_core_value(IkLimit, IK_LIMIT_LAYOUT, &defaults_ik_limit)!;
    register_core_value(IkAuthoring, IK_AUTHORING_LAYOUT, &defaults_ik)!;
    register_core_value(FootAuthoring, FOOT_AUTHORING_LAYOUT, &defaults_foot)!;
    register_core_value(LookAuthoring, LOOK_AUTHORING_LAYOUT, &defaults_look)!;
    register_described_owner(SkinBinding, SkinAuthoring, {
        .name = "c3d.SkinBinding", .phase = REFERENCES,
        .project = &project_skin, .validate = &validate_skin, .attach = &attach_skin,
    })!;
    register_described_owner(IkChain, IkAuthoring, {
        .name = "c3d.IkChain", .phase = REFERENCES,
        .project = &project_ik, .validate = &validate_ik, .attach = &attach_ik,
    })!;
    register_described_owner(FootIk, FootAuthoring, {
        .name = "c3d.FootIk", .phase = REFERENCES,
        .project = &project_foot, .validate = &validate_foot, .attach = &attach_foot,
    })!;
    register_described_owner(LookAt, LookAuthoring, {
        .name = "c3d.LookAt", .phase = REFERENCES,
        .project = &project_look, .validate = &validate_look, .attach = &attach_look,
    })!;
}

fn void defaults_skin(void* value) @local { *(SkinAuthoring*)value = {}; }
fn void defaults_ik_limit(void* value) @local { *(IkLimit*)value = {}; }

fn void defaults_ik(void* value) @local {
    IkAuthoring* chain = value;
    *chain = { .target = { .template_index = INDEX_NONE }, .pole = { .template_index = INDEX_NONE }, .weight = 1 };
    chain.joints[..] = { .template_index = INDEX_NONE };
}

fn void defaults_foot(void* value) @local {
    FootAuthoring* foot = value;
    FootIk defaults = ik::foot_ik(hip: null, knee: null, ankle: null, target: null);
    *foot = {
        .foot_height = defaults.foot_height, .lift_fade = defaults.lift_fade,
        .ray_height = defaults.ray_height, .ray_length = defaults.ray_length,
    };
    defaults_ik(&foot.leg);
}

fn void defaults_look(void* value) @local {
    *(LookAuthoring*)value = {
        .target = { .template_index = INDEX_NONE }, .forward = { 0, 0, -1 },
        .max_angle = (float)math::PI, .weight = 1,
    };
}

fn void? project_skin(void* component, void* value, WriteContext* context) @local {
    SkinBinding* skin = component;
    SkeletonAsset* skeleton = context.assets.skeletons.try_get(skin.skeleton)!;
    if (skin.joints.len != skeleton.data.parents.len) return c3d::INVALID_ARGUMENT~;
    NodeReference[] joints = alloc::new_array_try(tmem, NodeReference, skin.joints.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    foreach (index, joint : skin.joints) joints[index] = make_skin_reference(context, joint)!;
    *(SkinAuthoring*)value = { .skeleton = skin.skeleton, .joints = joints };
}

fn NodeReference? make_skin_reference(WriteContext* context, Node* node) @local {
    if (!node) return c3d::INVALID_ID~;
    usz address = (usz)node;
    usz first = (usz)context.scene.nodes.ptr;
    if (address < first || address - first >= context.scene.nodes.len * Node::size
        || (address - first) % Node::size != 0) return c3d::INVALID_ARGUMENT~;
    // Removed slots have cleared IDs, but skin references retain their addresses.
    usz index = (address - first) / Node::size;
    ExportNodeOwners* owners = &context.state.projection[index].owners;
    if (owners.absent_model.generation) {
        ModelInstance* instance = context.scene.get(context.scene.node(owners.absent_model), ModelInstance);
        return model_diagnostic(
            diagnostic: context.diagnostic,
            assets: context.assets,
            model: instance.source,
            index: owners.absent_template_index,
            cause: c3d::INVALID_ID,
        )~;
    }
    return context.make_node_reference(node, true);
}

fn void? validate_skin(void* value, ReadContext* context) @local {
    SkinAuthoring* skin = value;
    SkeletonAsset* skeleton = context.assets.skeletons.try_get(skin.skeleton)!;
    if (skin.joints.len != skeleton.data.parents.len) return c3d::INVALID_ARGUMENT~;
    foreach (joint : skin.joints) (void)context.resolve_node_reference(joint, true)!;
}

fn void? attach_skin(void* value, ReadContext* context) @local {
    SkinAuthoring* skin = value;
    Node*[] joints = alloc::new_array_try(context.scene.allocator, Node*, skin.joints.len)
      ?? c3d::CAPACITY_EXCEEDED~!;
    defer catch alloc::free(context.scene.allocator, joints.ptr);
    foreach (index, joint : skin.joints) joints[index] = context.resolve_node_reference(joint, true)!;
    context.scene.add(context.node, (SkinBinding){ .skeleton = skin.skeleton, .joints = joints });
}

fn IkAuthoring? project_chain(IkChain* chain, WriteContext* context) @local {
    IkAuthoring value = { .weight = chain.weight, .limits = chain.limits };
    foreach (index, joint : chain.joints) {
        value.joints[index] = context.make_node_reference(joint, true, c3d::INVALID_ARGUMENT)!;
    }
    value.target = context.make_node_reference(chain.target, true, c3d::INVALID_ARGUMENT)!;
    value.pole = context.make_node_reference(chain.pole)!;
    if (!ik::ik_chain_valid(chain)) return c3d::INVALID_ARGUMENT~;
    return value;
}

fn IkChain? restore_chain(IkAuthoring* source, ReadContext* context) @local {
    IkChain chain = { .weight = source.weight, .limits = source.limits };
    foreach (index, joint : source.joints) {
        chain.joints[index] = context.resolve_node_reference(joint, true, c3d::INVALID_ARGUMENT)!;
    }
    chain.target = context.resolve_node_reference(source.target, true, c3d::INVALID_ARGUMENT)!;
    chain.pole = context.resolve_node_reference(source.pole)!;
    if (!ik::ik_chain_valid(&chain)) return c3d::INVALID_ARGUMENT~;
    return chain;
}

fn void? project_ik(void* component, void* value, WriteContext* context) @local {
    *(IkAuthoring*)value = project_chain((IkChain*)component, context)!;
}

fn void? validate_ik(void* value, ReadContext* context) @local {
    (void)restore_chain((IkAuthoring*)value, context)!;
}

fn void? attach_ik(void* value, ReadContext* context) @local {
    context.scene.add(context.node, restore_chain((IkAuthoring*)value, context)!);
}

fn void? project_foot(void* component, void* value, WriteContext* context) @local {
    FootIk* foot = component;
    if (!(foot.lift_fade > 0)) return c3d::INVALID_ARGUMENT~;
    *(FootAuthoring*)value = {
        .leg = project_chain(&foot.leg, context)!, .foot_height = foot.foot_height,
        .lift_fade = foot.lift_fade, .ray_height = foot.ray_height, .ray_length = foot.ray_length,
    };
}

fn void? validate_foot(void* value, ReadContext* context) @local {
    FootAuthoring* foot = value;
    (void)restore_chain(&foot.leg, context)!;
    if (!(foot.lift_fade > 0)) return c3d::INVALID_ARGUMENT~;
}

fn void? attach_foot(void* value, ReadContext* context) @local {
    FootAuthoring* foot = value;
    context.scene.add(context.node, (FootIk){
        .leg = restore_chain(&foot.leg, context)!, .foot_height = foot.foot_height,
        .lift_fade = foot.lift_fade, .ray_height = foot.ray_height, .ray_length = foot.ray_length,
    });
}

fn void? project_look(void* component, void* value, WriteContext* context) @local {
    LookAt* look = component;
    NodeReference[] joints = alloc::new_array_try(tmem, NodeReference, look.joint_count)
      ?? c3d::CAPACITY_EXCEEDED~!;
    foreach (index, &reference : joints) {
        *reference = context.make_node_reference(look.joints[index], true, c3d::INVALID_ARGUMENT)!;
    }
    if (!ik::look_at_valid(look)) return c3d::INVALID_ARGUMENT~;
    *(LookAuthoring*)value = {
        .joints = joints, .weights = look.weights[:look.joint_count],
        .target = context.make_node_reference(look.target, true, c3d::INVALID_ARGUMENT)!,
        .forward = look.forward, .max_angle = look.max_angle, .weight = look.weight,
    };
}

fn LookAt? restore_look(LookAuthoring* source, ReadContext* context) @local {
    if (!source.joints.len || source.joints.len > ik::MAX_LOOK_AT_JOINTS
        || source.weights.len != source.joints.len) return c3d::INVALID_ARGUMENT~;
    LookAt look = {
        .joint_count = (uint)source.joints.len, .forward = source.forward,
        .max_angle = source.max_angle, .weight = source.weight,
        .target = context.resolve_node_reference(source.target, true, c3d::INVALID_ARGUMENT)!,
    };
    foreach (index, reference : source.joints) {
        look.joints[index] = context.resolve_node_reference(reference, true, c3d::INVALID_ARGUMENT)!;
        look.weights[index] = source.weights[index];
    }
    if (!ik::look_at_valid(&look)) return c3d::INVALID_ARGUMENT~;
    return look;
}

fn void? validate_look(void* value, ReadContext* context) @local {
    (void)restore_look((LookAuthoring*)value, context)!;
}

fn void? attach_look(void* value, ReadContext* context) @local {
    context.scene.add(context.node, restore_look((LookAuthoring*)value, context)!);
}
