module c3d::serial;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::scene;

struct ReadModelMap @private {
    Node* root;
    ModelId source;
    Entity[] nodes;
    ModelAuthoring* authoring;
}

fn bool model_codec_slot(uint slot) @private {
    DescribedBinding* binding = codecs[slot].described;
    return binding && binding.type.descriptor.identity == ModelAuthoring::typeid;
}

fn void? prepare_binary_models(
    ReadContext* context,
    PayloadView[] payloads,
    TypeRecord[] types,
    Acquisitions* owned,
) @private {
    uint count;
    foreach (payload : payloads) if (model_codec_slot(types[payload.type].slot)) count++;
    ReadModelMap* maps = owned.acquire(count, ReadModelMap::size, ReadModelMap::alignment)!;
    context.models = maps[:count];
    uint index;
    foreach (payload : payloads) {
        TypeRecord type = types[payload.type];
        if (!model_codec_slot(type.slot)) continue;
        DescribedBinding* binding = codecs[type.slot].described;
        if (type.version != binding.type.version) return c3d::UNSUPPORTED~;
        context.node = context.nodes[payload.record];
        context.record = payload.record;
        context.slot = type.slot;
        context.version = type.version;
        ModelAuthoring* value = context.authored(ModelInstance, ModelAuthoring, context.node.id)!;
        maps[index++] = {
            .root = context.node, .source = value.source, .nodes = value.nodes, .authoring = value,
        };
    }
    validate_model_maps(context, owned)!;
}

fn void? prepare_json_models(
    ReadContext* context,
    JsonComponentRecord[] components,
    Acquisitions* owned,
) @private {
    uint count;
    foreach (component : components) if (model_codec_slot(component.slot)) count++;
    ReadModelMap* maps = owned.acquire(count, ReadModelMap::size, ReadModelMap::alignment)!;
    context.models = maps[:count];
    uint index;
    foreach (component : components) {
        if (!model_codec_slot(component.slot)) continue;
        ModelAuthoring* value = component.decoded;
        maps[index++] = {
            .root = context.nodes[component.node],
            .source = value.source,
            .nodes = value.nodes,
            .authoring = value,
        };
    }
    validate_model_maps(context, owned)!;
}

fn void? validate_model_maps(ReadContext* context, Acquisitions* owned) @local {
    if (!context.models.len) return;
    bool* claimed = owned.acquire(context.nodes.len, bool::size, bool::alignment)!;
    foreach (model : context.models) {
        context.node = model.root;
        context.record = read_node_record(context, model.root.id)!;
        if (catch excuse = validate_model(model.authoring, context)) {
            return component_diagnostic(
                diagnostic: context.diagnostic,
                record: context.record,
                type_name: "c3d.ModelInstance",
                cause: excuse,
            )~;
        }
        foreach (entity : model.nodes) {
            if (!entity.generation) continue;
            uint record = read_node_record(context, entity)!;
            if (claimed[record]) return c3d::ASSET_FORMAT_ERROR~;
            claimed[record] = true;
        }
    }
}

fn bool? restore_cached_model(ReadContext* context) @private {
    if (!model_codec_slot(context.slot)) return false;
    foreach (model : context.models) {
        if (model.root != context.node) continue;
        codecs[context.slot].described.codec.attach(model.authoring, context)!;
        return true;
    }
    return c3d::ASSET_FORMAT_ERROR~;
}

fn void? validate_model_selection(WriteContext* context) @private {
    context.scene.@each(ModelInstance; entity, instance) {
        bool selected = context.state.projection[entity.index].selected;
        for (usz index = 0; index < instance.nodes.len; index++) {
            Node* node = instance.present_node(index);
            if (!node) continue;
            if (context.state.projection[node.id.index].selected && !selected) return c3d::INVALID_ARGUMENT~;
        }
    };
}

fn fault model_diagnostic(
    SerialDiagnostic* diagnostic,
    AssetStore* assets,
    ModelId model,
    uint index,
    fault cause,
) @private {
    if (!diagnostic) return cause;
    diagnostic.cause = cause;
    alloc::free(diagnostic.allocator, diagnostic.model_key.ptr);
    diagnostic.model_key = {};
    diagnostic.template_index = index;
    diagnostic.has_template_index = true;
    String key = assets.models.is_live(model) ? assets.model(model).header.key : "";
    if (try copy = copy_serial_string(diagnostic.allocator, key)) {
        diagnostic.model_key = copy;
        return cause;
    }
    clear_serial_diagnostic(diagnostic);
    diagnostic.cause = c3d::CAPACITY_EXCEEDED;
    return c3d::CAPACITY_EXCEEDED;
}
