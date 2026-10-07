module c3d::serial;

import c3d;
import c3d::asset;
import c3d::ecs;
import c3d::scene;

struct JsonNodeRecord @private {
    NodeRecord node;
    uint token;
    uint components;
}

struct JsonComponentRecord @private {
    uint node;
    uint slot;
    uint version;
    uint value;
    void* decoded;
}

<*
 Restore a JSONC subtree under the supplied parent.
 @param [&inout] scene : "Owns copied nodes and components."
 @param [&in] assets : "Contains every referenced key; unchanged."
 @param [in] parent : "Live parent with current world matrices; null selects root."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require parent == null || scene.world.is_alive(parent.id)
 @require parent == null || &scene.nodes[parent.id.index] == parent
*>
fn Node*? read_subtree_text(
    Scene* scene,
    AssetStore* assets,
    String text,
    Node* parent = null,
    ReadOptions options = READ_OPTIONS_DEFAULT,
) {
    Allocator allocator = options.allocator.ptr ? options.allocator : scene.allocator;
    SerialDiagnostic local = create_serial_diagnostic(allocator);
    defer destroy_serial_diagnostic(&local);
    SerialDiagnostic* diagnostic = options.diagnostic ? options.diagnostic : &local;
    clear_serial_diagnostic(diagnostic);
    Node*? restored = restore_subtree_json(
        scene: scene,
        assets: assets,
        text: text,
        parent: parent,
        options: options,
        allocator: allocator,
        diagnostic: diagnostic,
    );
    if (catch excuse = restored) {
        if (!diagnostic.cause) diagnostic.cause = excuse;
        return excuse~;
    }
    return restored;
}

fn Node*? restore_subtree_json(
    Scene* scene,
    AssetStore* assets,
    String text,
    Node* parent,
    ReadOptions options,
    Allocator allocator,
    SerialDiagnostic* diagnostic,
) @local {
    TextDocument document = parse_text(
        allocator: allocator,
        source: text,
        limits: options.limits,
        diagnostic: diagnostic,
    )!;
    defer destroy_text_document(&document);
    json_require_kind(
        document: &document,
        token: 0,
        kind: TextKind.OBJECT,
        diagnostic: diagnostic,
    )!;
    json_known_members(
        document: &document,
        object: 0,
        names: { "version", "nodes" },
        skip_unknown: options.skip_unknown,
        diagnostic: diagnostic,
    )!;
    uint version = json_uint_member(
        document: &document,
        object: 0,
        name: "version",
        diagnostic: diagnostic,
    )!;
    if (version != SUBTREE_VERSION) {
        uint token = json_required_member(
            document: &document,
            object: 0,
            name: "version",
            diagnostic: diagnostic,
        )!;
        return text_error(
            document: &document,
            value: token,
            cause: c3d::UNSUPPORTED,
            diagnostic: diagnostic,
        )~;
    }
    uint nodes_token = json_required_member(
        document: &document,
        object: 0,
        name: "nodes",
        diagnostic: diagnostic,
    )!;
    json_require_kind(
        document: &document,
        token: nodes_token,
        kind: TextKind.ARRAY,
        diagnostic: diagnostic,
    )!;
    uint count = document.values[nodes_token].children;
    if (!count) return text_error(
        document: &document,
        value: nodes_token,
        cause: c3d::ASSET_FORMAT_ERROR,
        diagnostic: diagnostic,
    )~;
    if (count > scene.world.entities.free_count) {
        return text_error(
            document: &document,
            value: nodes_token,
            cause: c3d::CAPACITY_EXCEEDED,
            diagnostic: diagnostic,
        )~;
    }
    Acquisitions owned = { .allocator = allocator };
    defer owned.release();
    JsonNodeRecord* record_storage = owned.acquire(count, JsonNodeRecord::size, JsonNodeRecord::alignment)!;
    JsonNodeRecord[] records = record_storage[:count];
    for (uint token = nodes_token + 1; token < document.values[nodes_token].end; token = document.values[token].end) {
        json_require_kind(
            document: &document,
            token: token,
            kind: TextKind.OBJECT,
            diagnostic: diagnostic,
        )!;
        uint id_token = json_required_member(
            document: &document,
            object: token,
            name: "id",
            diagnostic: diagnostic,
        )!;
        uint id = (uint)text_read_unsigned(
            document: &document,
            value: id_token,
            maximum: uint::max,
            diagnostic: diagnostic,
        )!;
        if (id >= count || records[id].token) {
            return text_error(
                document: &document,
                value: id_token,
                cause: c3d::ASSET_FORMAT_ERROR,
                diagnostic: diagnostic,
            )~;
        }
        records[id] = read_json_node(
            document: &document,
            token: token,
            skip_unknown: options.skip_unknown,
            diagnostic: diagnostic,
        )!;
    }
    uint* order_storage = owned.acquire(count, uint::size, uint::alignment)!;
    uint[] order = order_storage[:count];
    order_json_nodes(
        document: &document,
        records: records,
        order: order,
        owned: &owned,
        diagnostic: diagnostic,
    )!;
    JsonComponentRecord[] components = collect_json_components(
        document: &document,
        scene: scene,
        records: records,
        owned: &owned,
        skip_unknown: options.skip_unknown,
        diagnostic: diagnostic,
    )!;
    Node** node_storage = owned.acquire(count, Node*::size, Node*::alignment)!;
    Node*[] nodes = node_storage[:count];
    ComponentMask* mask_storage = owned.acquire(count, ComponentMask::size, ComponentMask::alignment)!;
    ComponentMask[] masks = mask_storage[:count];
    foreach (component : components) masks[component.node] |= ecs::slot_bit(component.slot);
    if (!parent) parent = scene.root;
    uint root_record = order[0];
    Node* root = scene.add_node(parent, records[root_record].node.name)!;
    defer catch scene.remove(root);
    foreach (position, record : order) {
        NodeRecord* saved = &records[record].node;
        Node* node = position ? scene.add_node(nodes[saved.parent], saved.name)! : root;
        nodes[record] = node;
        node.local = saved.local;
        node.transform_space = saved.transform_space;
        node.layers = saved.layers;
        node.visible = saved.visible;
        node.world = node.transform_space == TransformSpace.WORLD
          ? node.local.to_mat4() : node.parent.world.mul(node.local.to_mat4());
        node.visible_effective = node.visible && node.parent.visible_effective;
    }
    ReadContext context = {
        .scene = scene,
        .assets = assets,
        .allocator = allocator,
        .diagnostic = diagnostic,
        .nodes = nodes,
        .component_masks = masks,
    };
    foreach (&component : components) {
        select_json_component(&context, component);
        DescribedType* type = codecs[component.slot].described.type;
        component.decoded = owned.acquire(1, type.descriptor.size, type.descriptor.alignment)!;
        if (catch excuse = read_described_json(
            type: type,
            document: &document,
            token: component.value,
            context: &context,
            owned: &owned,
            diagnostic: diagnostic,
            skip_unknown: options.skip_unknown,
            value: component.decoded,
        )) {
            return json_component_diagnostic(
                document: &document,
                records: records,
                component: component,
                diagnostic: diagnostic,
                cause: excuse,
            )~;
        }
    }
    ReadAuthoring* authoring_storage = owned.acquire(
        count: (usz)components.len, element_size: ReadAuthoring::size, alignment: ReadAuthoring::alignment,
    )!;
    context.authoring = authoring_storage[:components.len];
    context.read_owned = &owned;
    foreach (index, component : components) {
        authoring_storage[index] = {
            .record = component.node, .slot = component.slot, .version = component.version, .value = component.decoded,
        };
    }
    index_read_authoring(&context)!;
    if (catch excuse = prepare_json_models(&context, components, &owned)) {
        foreach (&component : components) {
            if (component.node == context.record && model_codec_slot(component.slot)) {
                return json_component_diagnostic(
                    document: &document,
                    records: records,
                    component: component,
                    diagnostic: diagnostic,
                    cause: excuse,
                )~;
            }
        }
        return excuse~;
    }
    foreach (component : components) {
        if (model_codec_slot(component.slot)) continue;
        ValidateFn validate = codecs[component.slot].described.codec.validate;
        if (!validate) continue;
        select_json_component(&context, &component);
        if (catch excuse = validate(component.decoded, &context)) {
            return json_component_diagnostic(
                document: &document,
                records: records,
                component: &component,
                diagnostic: diagnostic,
                cause: excuse,
            )~;
        }
    }
    foreach (phase : RestorePhase::values) {
        foreach (component : components) {
            if (codecs[component.slot].codec.phase != phase) continue;
            select_json_component(&context, &component);
            if (catch excuse = codecs[component.slot].described.codec.attach(component.decoded, &context)) {
                return json_component_diagnostic(
                    document: &document,
                    records: records,
                    component: &component,
                    diagnostic: diagnostic,
                    cause: excuse,
                )~;
            }
        }
    }
    return root;
}

fn void select_json_component(ReadContext* context, JsonComponentRecord* component) @local {
    context.node = context.nodes[component.node];
    context.record = component.node;
    context.version = component.version;
    context.slot = component.slot;
}

fn fault json_component_diagnostic(
    TextDocument* document,
    JsonNodeRecord[] records,
    JsonComponentRecord* component,
    SerialDiagnostic* diagnostic,
    fault cause,
) @local {
    if (!diagnostic.has_text_position) {
        cause = enrich_text_error(
            document: document,
            token: component.value,
            cause: cause,
            diagnostic: diagnostic,
        );
    }
    uint record = document.values[records[component.node].token].index;
    return component_diagnostic(
        diagnostic: diagnostic,
        record: record,
        type_name: codecs[component.slot].codec.name,
        cause: cause,
    );
}
