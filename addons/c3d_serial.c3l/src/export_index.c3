module c3d::serial;

import c3d;
import c3d::ecs;
import c3d::scene;

fn void index_export_owners(WriteContext* context) @private {
    context.scene.@each(ModelInstance; entity, instance) {
        foreach (index, captured : instance.node_entities) {
            if (!captured.generation) continue;
            ExportNodeOwners* owners = &context.state.projection[captured.index].owners;
            if (instance.present_node((usz)index)) {
                owners.model = entity;
                owners.template_index = (uint)index;
                owners.baseline_slot = INDEX_NONE;
            } else if (!owners.absent_model.generation || entity.index < owners.absent_model.index) {
                // The lowest owner index makes stale skin diagnostics independent of store order.
                owners.absent_model = entity;
                owners.absent_template_index = (uint)index;
            }
        }
        foreach (index, template_node : instance.mesh_nodes) {
            if (Node* node = instance.present_node(template_node)) {
                context.state.projection[node.id.index].owners.baseline_slot = (uint)index;
            }
        }
    };
    context.scene.@each(AnimatedCrowd; entity, crowd) {
        foreach (part : crowd.parts) {
            if (context.scene.world.is_alive(part.batch)) {
                context.state.projection[part.batch.index].owners.crowd = entity;
            }
        }
    };
}

fn fault dead_entity_diagnostic(WriteContext* context, Entity entity, fault missing) @private {
    if (!context.diagnostic) return missing;
    context.scene.@each(ModelInstance; owner, instance) {
        foreach (index, captured : instance.node_entities) {
            if (c3d::same_id(captured, entity)) return model_diagnostic(
                diagnostic: context.diagnostic,
                assets: context.assets,
                model: instance.source,
                index: (uint)index,
                cause: missing,
            );
        }
    };
    return missing;
}
