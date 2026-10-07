module c3d::serial;

import c3d;

fn uint json_member(TextDocument* document, uint object, String name) @private {
    for (uint child = object + 1; child < document.values[object].end; child = document.values[child].end) {
        if (document.values[child].name == name) return child;
    }
    return INDEX_NONE;
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
