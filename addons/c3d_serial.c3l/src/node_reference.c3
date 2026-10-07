module c3d::serial;

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import c3d::scene;

const ulong NODE_REFERENCE_LAYOUT @local = 0x4f6fd83989662b2a;

<* Document node or stable template slot within a document model. *>
struct NodeReference {
    Entity node;
    Entity model;
    uint template_index;
}

<*
 Capture a live node using its current entity identity.
 @param [in] node : "Null or storage belonging to the source scene."
 @param missing : "Owner fault for a missing required node."
 @return "Portable reference or the unchanged owner fault."
 @return? c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::CAPACITY_EXCEEDED
*>
fn NodeReference? WriteContext.make_node_reference(
    &self,
    Node* node,
    bool required = false,
    fault missing = c3d::INVALID_ID,
) {
    if (!node) {
        if (required) return missing~;
        return (NodeReference){ .template_index = INDEX_NONE };
    }
    return self.make_entity_reference(node.id, required, missing);
}

<*
 Capture an entity reference with its original template identity.
 @param missing : "Owner fault for a missing required entity."
 @return "Portable reference or the unchanged owner fault."
 @return? c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::CAPACITY_EXCEEDED
*>
fn NodeReference? WriteContext.make_entity_reference(
    &self,
    Entity entity,
    bool required = false,
    fault missing = c3d::INVALID_ID,
) {
    if (!entity.index && !entity.generation) {
        if (required) return missing~;
        return (NodeReference){ .template_index = INDEX_NONE };
    }
    self.scene.@each(ModelInstance; owner, instance) {
        foreach (usz index, captured : instance.node_entities) {
            if (!c3d::same_id(captured, entity)) continue;
            Node* node = instance.present_node(index);
            if (!node) return model_diagnostic(
                diagnostic: self.diagnostic,
                assets: self.assets,
                model: instance.source,
                index: (uint)index,
                cause: missing,
            )~;
            (void)projection_of(self, node)!;
            (void)projection_of(self, self.scene.node(owner))!;
            return (NodeReference){ .model = owner, .template_index = (uint)index };
        }
    };
    if (!self.scene.world.is_alive(entity)) return missing~;
    (void)projection_of(self, self.scene.node(entity))!;
    return (NodeReference){ .node = entity, .template_index = INDEX_NONE };
}

<*
 Resolve a saved node against preflighted model mappings.
 @param missing : "Owner fault for an absent required target."
 @return "Resolved node, null when optional, or unchanged owner fault."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID, c3d::CAPACITY_EXCEEDED
*>
fn Node*? ReadContext.resolve_node_reference(
    &self,
    NodeReference reference,
    bool required = false,
    fault missing = c3d::INVALID_ID,
) {
    if (reference.model.generation) {
        if (reference.node.generation) return c3d::ASSET_FORMAT_ERROR~;
        foreach (model : self.models) {
            if (!c3d::same_id(model.root.id, reference.model)) continue;
            if (reference.template_index >= model.nodes.len) return c3d::ASSET_FORMAT_ERROR~;
            Entity entity = model.nodes[reference.template_index];
            if (!entity.generation) {
                if (!required) return (Node*)null;
                return model_diagnostic(
                    diagnostic: self.diagnostic,
                    assets: self.assets,
                    model: model.source,
                    index: reference.template_index,
                    cause: missing,
                )~;
            }
            return self.scene.node(entity);
        }
        return missing~;
    }
    if (reference.template_index != INDEX_NONE) return c3d::ASSET_FORMAT_ERROR~;
    if (!reference.node.generation) {
        if (required) return missing~;
        return (Node*)null;
    }
    return self.scene.node(reference.node);
}

fn void? register_node_reference_type() @private {
    describe::register_reflected(NodeReference)!;
    register_core_value(NodeReference, NODE_REFERENCE_LAYOUT, &defaults_node_reference)!;
}

fn void defaults_node_reference(void* value) @local {
    *(NodeReference*)value = { .template_index = INDEX_NONE };
}
