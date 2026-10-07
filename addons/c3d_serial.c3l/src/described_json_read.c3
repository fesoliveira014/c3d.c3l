module c3d::serial;

import c3d;
import c3d::asset;
import c3d::describe;
import c3d::ecs;
import std::core::mem;
import std::core::runtime;

struct DefaultCloneState @private {
    Acquisitions* owned;
    uint depth;
}

struct DescribedJsonScope @private {
    uint token;
    uint next;
    bool object;
    bool fresh_elements;
}

struct DescribedJsonRead @private {
    TextDocument* document;
    ReadContext* context;
    Acquisitions* owned;
    SerialDiagnostic* diagnostic;
    bool[] seen;
    DescribedJsonScope[TEXT_MAX_DEPTH] scopes;
    uint root;
    uint depth;
    uint last_token;
    bool fresh;
    bool skip_unknown;
}

fn void? read_described_json(
    DescribedType* type,
    TextDocument* document,
    uint token,
    ReadContext* context,
    Acquisitions* owned,
    SerialDiagnostic* diagnostic,
    bool skip_unknown,
    void* value,
) @private {
    clear_serial_diagnostic(diagnostic);
    json_require_kind(
        document: document,
        token: token,
        kind: TextKind.OBJECT,
        diagnostic: diagnostic,
    )!;
    DescribedJsonRead state = {
        .document = document,
        .context = context,
        .owned = owned,
        .diagnostic = diagnostic,
        .root = token,
        .last_token = token,
        .skip_unknown = skip_unknown,
    };
    if (catch excuse = initialize_described_json(type, &state, value)) {
        if (!diagnostic.has_text_position) return enrich_text_error(
            document: document,
            token: state.last_token,
            cause: excuse,
            diagnostic: diagnostic,
        )~;
        return excuse~;
    }
    describe::Visitor visitor = {
        .mode = READ,
        .field = &described_json_read_field,
        .begin = &described_json_read_begin,
        .end = &described_json_read_end,
        .user = &state,
    };
    if (catch excuse = describe::walk_descriptor(type.descriptor, &visitor, value)) {
        if (!diagnostic.has_text_position) return enrich_text_error(
            document: document,
            token: state.last_token,
            cause: excuse,
            diagnostic: diagnostic,
        )~;
        return excuse~;
    }
}

fn void? initialize_described_json(DescribedType* type, DescribedJsonRead* state, void* value) @local {
    usz count = (usz)(state.document.values[state.root].end - state.root);
    bool* seen = state.owned.acquire(count, bool::size, bool::alignment)!;
    state.seen = seen[:count];
    type.defaults(value);
    clone_described_defaults(type.descriptor, state.owned, value)!;
}

fn void? clone_described_defaults(describe::Descriptor* descriptor, Acquisitions* owned, void* value) @local {
    DefaultCloneState state = { .owned = owned };
    describe::Visitor visitor = {
        .mode = WRITE,
        .field = &clone_default_field,
        .begin = &clone_default_begin,
        .end = &clone_default_end,
        .user = &state,
    };
    describe::walk_descriptor(descriptor, &visitor, value)!;
}

fn bool? clone_default_begin(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    DefaultCloneState* state = visitor.user;
    if (state.depth == TEXT_MAX_DEPTH) return c3d::CAPACITY_EXCEEDED~;
    state.depth++;
    if (info.kind == STRUCT) {
        (void)find_described_type(info.identity)!;
    } else if (info.kind == SLICE) {
        SliceRaw* slice = value;
        void* source = slice.ptr;
        usz count = (usz)slice.len;
        void* copy = state.owned.acquire(
            count: count,
            element_size: info.element_size,
            alignment: info.element_alignment,
        )!;
        if (count) mem::copy(copy, source, (sz)(count * info.element_size));
        slice.ptr = copy;
    }
    return true;
}

fn void? clone_default_end(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    DefaultCloneState* state = visitor.user;
    state.depth--;
}

fn bool? clone_default_field(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    if (info.kind != STRING) return false;
    DefaultCloneState* state = visitor.user;
    String source = *(String*)value;
    char* copy = state.owned.acquire(source.len, char::size, char::alignment)!;
    if (source.len) mem::copy(copy, source.ptr, source.len);
    *(String*)value = (String)copy[:source.len];
    return false;
}

fn uint select_described_json(DescribedJsonRead* state, String name) @local {
    state.fresh = false;
    if (!state.depth) return state.root;
    DescribedJsonScope* scope = &state.scopes[state.depth - 1];
    if (scope.object) {
        uint token = json_member(state.document, scope.token, name);
        if (token != INDEX_NONE) state.seen[token - state.root] = true;
        return token;
    }
    uint token = scope.next;
    scope.next = state.document.values[token].end;
    state.fresh = scope.fresh_elements;
    return token;
}

fn bool? described_json_read_begin(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    DescribedJsonRead* state = visitor.user;
    uint token = select_described_json(state, info.name);
    if (token == INDEX_NONE) return false;
    state.last_token = token;
    TextValue* input = &state.document.values[token];
    if (state.depth == TEXT_MAX_DEPTH) return c3d::CAPACITY_EXCEEDED~;
    bool fresh_elements;
    switch (info.kind) {
        case STRUCT:
            json_require_kind(
                document: state.document,
                token: token,
                kind: TextKind.OBJECT,
                diagnostic: state.diagnostic,
            )!;
            if (state.fresh) {
                DescribedType* type = find_described_type(info.identity)!;
                type.defaults(value);
                clone_described_defaults(type.descriptor, state.owned, value)!;
            }
        case ARRAY:
            json_require_kind(
                document: state.document,
                token: token,
                kind: TextKind.ARRAY,
                diagnostic: state.diagnostic,
            )!;
            if (input.children != info.extent) return c3d::ASSET_FORMAT_ERROR~;
            fresh_elements = state.fresh;
        case SLICE:
            json_require_kind(
                document: state.document,
                token: token,
                kind: TextKind.ARRAY,
                diagnostic: state.diagnostic,
            )!;
            SliceRaw* slice = value;
            slice.ptr = state.owned.acquire(
                count: input.children,
                element_size: info.element_size,
                alignment: info.element_alignment,
            )!;
            slice.len = input.children;
            fresh_elements = true;
        default: unreachable();
    }
    state.scopes[state.depth++] = {
        .token = token,
        .next = token + 1,
        .object = info.kind == STRUCT,
        .fresh_elements = fresh_elements,
    };
    return true;
}

fn void? described_json_read_end(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    DescribedJsonRead* state = visitor.user;
    DescribedJsonScope scope = state.scopes[--state.depth];
    state.last_token = scope.token;
    if (scope.object && !state.skip_unknown) {
        for (uint child = scope.token + 1; child < state.document.values[scope.token].end;
            child = state.document.values[child].end) {
            if (!state.seen[child - state.root]) return text_error(
                document: state.document,
                value: child,
                cause: c3d::ASSET_FORMAT_ERROR,
                diagnostic: state.diagnostic,
            )~;
        }
    }
}

fn bool? described_json_read_field(describe::Visitor* visitor, describe::Info* info, void* value) @local {
    DescribedJsonRead* state = visitor.user;
    uint token = select_described_json(state, info.name);
    if (token == INDEX_NONE) return false;
    state.last_token = token;
    decode_described_json_field(
        state: state,
        info: info,
        token: token,
        value: value,
    )!;
    return false;
}

fn void? decode_described_json_field(
    DescribedJsonRead* state,
    describe::Info* info,
    uint token,
    void* value,
) @local {
    TextDocument* document = state.document;
    SerialDiagnostic* diagnostic = state.diagnostic;
    TextValue* input = &document.values[token];
    switch (info.kind) {
        case BOOL:
            json_require_kind(
                document: document,
                token: token,
                kind: TextKind.BOOLEAN,
                diagnostic: diagnostic,
            )!;
            *(bool*)value = input.boolean;
        case ICHAR:
            *(ichar*)value = (ichar)text_read_signed(
                document: document,
                value: token,
                minimum: ichar::min,
                maximum: ichar::max,
                diagnostic: diagnostic,
            )!;
        case CHAR:
            *(char*)value = (char)text_read_unsigned(
                document: document,
                value: token,
                maximum: char::max,
                diagnostic: diagnostic,
            )!;
        case SHORT:
            *(short*)value = (short)text_read_signed(
                document: document,
                value: token,
                minimum: short::min,
                maximum: short::max,
                diagnostic: diagnostic,
            )!;
        case USHORT:
            *(ushort*)value = (ushort)text_read_unsigned(
                document: document,
                value: token,
                maximum: ushort::max,
                diagnostic: diagnostic,
            )!;
        case INT:
            *(int*)value = (int)text_read_signed(
                document: document,
                value: token,
                minimum: int::min,
                maximum: int::max,
                diagnostic: diagnostic,
            )!;
        case UINT:
            *(uint*)value = (uint)text_read_unsigned(
                document: document,
                value: token,
                maximum: uint::max,
                diagnostic: diagnostic,
            )!;
        case LONG: *(long*)value = text_read_long(document, token, diagnostic)!;
        case ULONG: *(ulong*)value = text_read_ulong(document, token, diagnostic)!;
        case FLOAT: *(float*)value = text_read_float(document, token, diagnostic)!;
        case DOUBLE: *(double*)value = text_read_double(document, token, diagnostic)!;
        case VEC2:
        case VEC3:
        case VEC4:
        case QUAT:
        case MAT4:
            json_float_lanes(
                document: document,
                token: token,
                values: value,
                count: described_lanes(info.kind),
                diagnostic: diagnostic,
            )!;
        case UVEC3:
            json_require_kind(
                document: document,
                token: token,
                kind: TextKind.ARRAY,
                diagnostic: diagnostic,
            )!;
            if (input.children != 3) return c3d::ASSET_FORMAT_ERROR~;
            uint index;
            for (uint child = token + 1; child < input.end; child = document.values[child].end) {
                ((uint*)value)[index++] = (uint)text_read_unsigned(
                    document: document,
                    value: child,
                    maximum: uint::max,
                    diagnostic: diagnostic,
                )!;
            }
        case STRING:
            json_require_kind(
                document: document,
                token: token,
                kind: TextKind.STRING,
                diagnostic: diagnostic,
            )!;
            char* copy = state.owned.acquire(input.string.len, char::size, char::alignment)!;
            if (input.string.len) mem::copy(copy, input.string.ptr, input.string.len);
            *(String*)value = (String)copy[:input.string.len];
        case ENUM:
            json_require_kind(
                document: document,
                token: token,
                kind: TextKind.STRING,
                diagnostic: diagnostic,
            )!;
            foreach (index, name : info.enum_names) {
                if (name == input.string) {
                    info.write_enum(value, (ulong)index)!;
                    return;
                }
            }
            return c3d::ASSET_FORMAT_ERROR~;
        case ENTITY:
            if (input.kind == TextKind.NIL) {
                *(Entity*)value = {};
            } else {
                uint index = (uint)text_read_unsigned(
                    document: document,
                    value: token,
                    maximum: uint::max,
                    diagnostic: diagnostic,
                )!;
                if (index >= state.context.nodes.len) return c3d::ASSET_FORMAT_ERROR~;
                *(Entity*)value = state.context.nodes[index].id;
            }
        case ASSET:
            if (input.kind == TextKind.NIL) {
                mem::clear(value, (sz)info.size);
            } else {
                json_require_kind(
                    document: document,
                    token: token,
                    kind: TextKind.STRING,
                    diagnostic: diagnostic,
                )!;
                read_json_asset(
                    context: state.context,
                    kind: info.metadata.asset_kind,
                    key: input.string,
                    value: value,
                )!;
            }
        case STRUCT:
        case ARRAY:
        case SLICE: unreachable();
    }
}

fn void? read_json_asset(
    ReadContext* context,
    AssetKind kind,
    String key,
    void* value,
) @local {
    if (catch excuse = find_json_asset(
        context: context,
        kind: kind,
        key: key,
        value: value,
    )) {
        return asset_diagnostic(context.diagnostic, key, excuse)~;
    }
}

fn void? find_json_asset(
    ReadContext* context,
    AssetKind kind,
    String key,
    void* value,
) @local {
    switch (kind) {
        case GEOMETRY: *(GeometryId*)value = context.assets.find_geometry(key) ?? c3d::INVALID_ID~!;
        case TEXTURE: *(TextureId*)value = context.assets.find_texture(key) ?? c3d::INVALID_ID~!;
        case SAMPLER: *(SamplerId*)value = context.assets.find_sampler(key) ?? c3d::INVALID_ID~!;
        case MATERIAL: *(MaterialId*)value = context.assets.find_material(key) ?? c3d::INVALID_ID~!;
        case MODEL: *(ModelId*)value = context.assets.find_model(key) ?? c3d::INVALID_ID~!;
        case CLIP: *(ClipId*)value = context.assets.find_clip(key) ?? c3d::INVALID_ID~!;
        case SKELETON: *(SkeletonId*)value = context.assets.find_skeleton(key) ?? c3d::INVALID_ID~!;
        case SHADER: *(ShaderId*)value = context.assets.find_shader(key) ?? c3d::INVALID_ID~!;
        case COMPUTE_SHADER: *(ComputeShaderId*)value = context.assets.find_compute_shader(key) ?? c3d::INVALID_ID~!;
        case ENVIRONMENT: *(EnvironmentId*)value = context.assets.find_environment(key) ?? c3d::INVALID_ID~!;
        case FONT: *(FontId*)value = context.assets.find_font(key) ?? c3d::INVALID_ID~!;
        case CUSTOM: return c3d::UNSUPPORTED~;
    }
}
