module c3d::serial;

import c3d;
import c3d::ecs;
import c3d::scene;

fn JsonNodeRecord? read_json_node(
    TextDocument* document,
    uint token,
    bool skip_unknown,
    SerialDiagnostic* diagnostic,
) @private {
    json_known_members(
        document: document,
        object: token,
        names: { "id", "parent", "name", "local", "transform_space", "layers", "visible", "components" },
        skip_unknown: skip_unknown,
        diagnostic: diagnostic,
    )!;
    JsonNodeRecord record = { .token = token };
    uint parent = json_required_member(
        document: document,
        object: token,
        name: "parent",
        diagnostic: diagnostic,
    )!;
    record.node.parent = document.values[parent].kind == TextKind.NIL
      ? INDEX_NONE : (uint)text_read_unsigned(
          document: document,
          value: parent,
          maximum: uint::max,
          diagnostic: diagnostic,
      )!;
    uint name = json_required_member(
        document: document,
        object: token,
        name: "name",
        diagnostic: diagnostic,
    )!;
    json_require_kind(
        document: document,
        token: name,
        kind: TextKind.STRING,
        diagnostic: diagnostic,
    )!;
    record.node.name = document.values[name].string;
    uint local = json_required_member(
        document: document,
        object: token,
        name: "local",
        diagnostic: diagnostic,
    )!;
    record.node.local = json_transform(
        document: document,
        token: local,
        skip_unknown: skip_unknown,
        diagnostic: diagnostic,
    )!;
    uint space = json_required_member(
        document: document,
        object: token,
        name: "transform_space",
        diagnostic: diagnostic,
    )!;
    json_require_kind(
        document: document,
        token: space,
        kind: TextKind.STRING,
        diagnostic: diagnostic,
    )!;
    bool found;
    foreach (value : TransformSpace::values) {
        if (document.values[space].string != TransformSpace::names[value.ordinal]) continue;
        record.node.transform_space = value;
        found = true;
        break;
    }
    if (!found) return text_error(
        document: document,
        value: space,
        cause: c3d::ASSET_FORMAT_ERROR,
        diagnostic: diagnostic,
    )~;
    record.node.layers = json_uint_member(
        document: document,
        object: token,
        name: "layers",
        diagnostic: diagnostic,
    )!;
    uint visible = json_required_member(
        document: document,
        object: token,
        name: "visible",
        diagnostic: diagnostic,
    )!;
    json_require_kind(
        document: document,
        token: visible,
        kind: TextKind.BOOLEAN,
        diagnostic: diagnostic,
    )!;
    record.node.visible = document.values[visible].boolean;
    record.components = json_required_member(
        document: document,
        object: token,
        name: "components",
        diagnostic: diagnostic,
    )!;
    json_require_kind(
        document: document,
        token: record.components,
        kind: TextKind.OBJECT,
        diagnostic: diagnostic,
    )!;
    return record;
}

fn void? order_json_nodes(
    TextDocument* document,
    JsonNodeRecord[] records,
    uint[] order,
    Acquisitions* owned,
    SerialDiagnostic* diagnostic,
) @private {
    uint root = INDEX_NONE;
    foreach (index, record : records) {
        uint parent = record.node.parent;
        if (parent == INDEX_NONE) {
            if (root != INDEX_NONE) {
                return text_error(
                    document: document,
                    value: record.token,
                    cause: c3d::ASSET_FORMAT_ERROR,
                    diagnostic: diagnostic,
                )~;
            }
            root = (uint)index;
        } else if (parent >= records.len) {
            uint token = json_member(document, record.token, "parent");
            return text_error(
                document: document,
                value: token,
                cause: c3d::ASSET_FORMAT_ERROR,
                diagnostic: diagnostic,
            )~;
        }
    }
    if (root == INDEX_NONE) return text_error(
        document: document,
        value: records[0].token,
        cause: c3d::ASSET_FORMAT_ERROR,
        diagnostic: diagnostic,
    )~;
    char* marks = owned.acquire(records.len, char::size, char::alignment)!;
    uint* chain = owned.acquire(records.len, uint::size, uint::alignment)!;
    uint next;
    foreach (index, ignored : records) {
        uint current = (uint)index;
        uint length;
        while (current != INDEX_NONE && !marks[current]) {
            marks[current] = 1;
            chain[length++] = current;
            current = records[current].node.parent;
        }
        if (current != INDEX_NONE && marks[current] == 1) {
            uint token = json_member(document, records[current].token, "parent");
            return text_error(
                document: document,
                value: token,
                cause: c3d::ASSET_FORMAT_ERROR,
                diagnostic: diagnostic,
            )~;
        }
        while (length) {
            uint record = chain[--length];
            marks[record] = 2;
            order[next++] = record;
        }
    }
}

fn JsonComponentRecord[]? collect_json_components(
    TextDocument* document,
    Scene* scene,
    JsonNodeRecord[] records,
    Acquisitions* owned,
    bool skip_unknown,
    SerialDiagnostic* diagnostic,
) @private {
    uint count;
    foreach (record : records) {
        uint parent = record.components;
        for (uint token = parent + 1; token < document.values[parent].end; token = document.values[token].end) {
            JsonComponentRecord component = json_component_record(
                document: document,
                scene: scene,
                token: token,
                skip_unknown: skip_unknown,
                diagnostic: diagnostic,
            )!;
            if (component.slot != INDEX_NONE) count++;
        }
    }
    JsonComponentRecord* storage = owned.acquire(count, JsonComponentRecord::size, JsonComponentRecord::alignment)!;
    JsonComponentRecord[] components = storage[:count];
    uint next;
    foreach (index, record : records) {
        uint parent = record.components;
        for (uint token = parent + 1; token < document.values[parent].end; token = document.values[token].end) {
            JsonComponentRecord component = json_component_record(
                document: document,
                scene: scene,
                token: token,
                skip_unknown: skip_unknown,
                diagnostic: diagnostic,
            )!;
            if (component.slot == INDEX_NONE) continue;
            component.node = (uint)index;
            components[next++] = component;
        }
    }
    return components;
}

fn JsonComponentRecord? json_component_record(
    TextDocument* document,
    Scene* scene,
    uint token,
    bool skip_unknown,
    SerialDiagnostic* diagnostic,
) @local {
    String name = document.values[token].name;
    uint? slot = codec_slot(name);
    if (catch excuse = slot) {
        if (skip_unknown) return { .slot = INDEX_NONE };
        return text_error(
            document: document,
            value: token,
            cause: c3d::UNSUPPORTED,
            diagnostic: diagnostic,
        )~;
    }
    DescribedBinding* binding = codecs[slot].described;
    if (!binding || !scene.world.stores[slot]) return text_error(
        document: document,
        value: token,
        cause: c3d::UNSUPPORTED,
        diagnostic: diagnostic,
    )~;
    json_require_kind(
        document: document,
        token: token,
        kind: TextKind.OBJECT,
        diagnostic: diagnostic,
    )!;
    json_known_members(
        document: document,
        object: token,
        names: { "version", "value" },
        skip_unknown: skip_unknown,
        diagnostic: diagnostic,
    )!;
    uint version_token = json_required_member(
        document: document,
        object: token,
        name: "version",
        diagnostic: diagnostic,
    )!;
    uint version = (uint)text_read_unsigned(
        document: document,
        value: version_token,
        maximum: uint::max,
        diagnostic: diagnostic,
    )!;
    if (!version) return text_error(
        document: document,
        value: version_token,
        cause: c3d::ASSET_FORMAT_ERROR,
        diagnostic: diagnostic,
    )~;
    bool supported = version == binding.type.version;
    foreach (compatible : binding.codec.text_default_versions) supported = supported || version == compatible;
    if (!supported) return text_error(
        document: document,
        value: version_token,
        cause: c3d::UNSUPPORTED,
        diagnostic: diagnostic,
    )~;
    uint value = json_required_member(
        document: document,
        object: token,
        name: "value",
        diagnostic: diagnostic,
    )!;
    json_require_kind(
        document: document,
        token: value,
        kind: TextKind.OBJECT,
        diagnostic: diagnostic,
    )!;
    return { .slot = slot, .version = version, .value = value };
}
