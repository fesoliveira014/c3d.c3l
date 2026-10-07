module c3d::serial;

import c3d;
import c3d::maths;

fn uint json_member(TextDocument* document, uint object, String name) @private {
    for (uint child = object + 1; child < document.values[object].end; child = document.values[child].end) {
        if (document.values[child].name == name) return child;
    }
    return INDEX_NONE;
}

fn uint? json_required_member(
    TextDocument* document,
    uint object,
    String name,
    SerialDiagnostic* diagnostic,
) @private {
    uint child = json_member(document, object, name);
    if (child == INDEX_NONE) return text_error(
        document: document,
        value: object,
        cause: c3d::ASSET_FORMAT_ERROR,
        diagnostic: diagnostic,
    )~;
    return child;
}

fn void? json_require_kind(
    TextDocument* document,
    uint token,
    TextKind kind,
    SerialDiagnostic* diagnostic,
) @private {
    if (document.values[token].kind != kind) {
        return text_error(
            document: document,
            value: token,
            cause: c3d::ASSET_FORMAT_ERROR,
            diagnostic: diagnostic,
        )~;
    }
}

fn void? json_known_members(
    TextDocument* document,
    uint object,
    String[] names,
    bool skip_unknown,
    SerialDiagnostic* diagnostic,
) @private {
    if (skip_unknown) return;
    for (uint child = object + 1; child < document.values[object].end; child = document.values[child].end) {
        bool known;
        foreach (name : names) known = known || name == document.values[child].name;
        if (!known) return text_error(
            document: document,
            value: child,
            cause: c3d::ASSET_FORMAT_ERROR,
            diagnostic: diagnostic,
        )~;
    }
}

fn uint? json_uint_member(
    TextDocument* document,
    uint object,
    String name,
    SerialDiagnostic* diagnostic,
) @private {
    uint child = json_required_member(
        document: document,
        object: object,
        name: name,
        diagnostic: diagnostic,
    )!;
    return (uint)text_read_unsigned(
        document: document,
        value: child,
        maximum: uint::max,
        diagnostic: diagnostic,
    )!;
}

fn void? json_float_lanes(
    TextDocument* document,
    uint token,
    float* values,
    uint count,
    SerialDiagnostic* diagnostic,
) @private {
    json_require_kind(
        document: document,
        token: token,
        kind: TextKind.ARRAY,
        diagnostic: diagnostic,
    )!;
    if (document.values[token].children != count) {
        return text_error(
            document: document,
            value: token,
            cause: c3d::ASSET_FORMAT_ERROR,
            diagnostic: diagnostic,
        )~;
    }
    uint index;
    for (uint child = token + 1; child < document.values[token].end; child = document.values[child].end) {
        values[index++] = text_read_float(document, child, diagnostic)!;
    }
}

fn Transform? json_transform(
    TextDocument* document,
    uint token,
    bool skip_unknown,
    SerialDiagnostic* diagnostic,
) @private {
    json_require_kind(
        document: document,
        token: token,
        kind: TextKind.OBJECT,
        diagnostic: diagnostic,
    )!;
    json_known_members(
        document: document,
        object: token,
        names: { "position", "rotation", "scale" },
        skip_unknown: skip_unknown,
        diagnostic: diagnostic,
    )!;
    Transform local;
    uint position = json_required_member(
        document: document,
        object: token,
        name: "position",
        diagnostic: diagnostic,
    )!;
    json_float_lanes(
        document: document,
        token: position,
        values: (float*)&local.position,
        count: 3,
        diagnostic: diagnostic,
    )!;
    uint rotation = json_required_member(
        document: document,
        object: token,
        name: "rotation",
        diagnostic: diagnostic,
    )!;
    json_float_lanes(
        document: document,
        token: rotation,
        values: (float*)&local.rotation,
        count: 4,
        diagnostic: diagnostic,
    )!;
    uint scale = json_required_member(
        document: document,
        object: token,
        name: "scale",
        diagnostic: diagnostic,
    )!;
    json_float_lanes(
        document: document,
        token: scale,
        values: (float*)&local.scale,
        count: 3,
        diagnostic: diagnostic,
    )!;
    return local;
}
