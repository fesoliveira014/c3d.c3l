module c3d::serial;

import c3d;
import std::io;

fn String? copy_serial_string(Allocator allocator, String source) @private {
    char[] copy = alloc::new_array_try(allocator, char, source.len) ?? c3d::CAPACITY_EXCEEDED~!;
    copy[..] = ((char[])source)[..];
    return (String)copy;
}

fn String? serial_node_path(Allocator allocator, uint record) @private {
    char[32] scratch;
    String path = (String)(io::bprintf(scratch[..], "/nodes/%s", record) ?? c3d::CAPACITY_EXCEEDED~!);
    return copy_serial_string(allocator, path);
}

fn fault component_diagnostic(
    SerialDiagnostic* diagnostic,
    uint record,
    String type_name,
    fault cause,
) @private {
    if (!diagnostic) return cause;
    diagnostic.cause = cause;
    alloc::free(diagnostic.allocator, diagnostic.node_path.ptr);
    alloc::free(diagnostic.allocator, diagnostic.type_name.ptr);
    diagnostic.node_path = {};
    diagnostic.type_name = {};
    if (try path = serial_node_path(diagnostic.allocator, record)) {
        diagnostic.node_path = path;
    } else {
        clear_serial_diagnostic(diagnostic);
        diagnostic.cause = c3d::CAPACITY_EXCEEDED;
        return c3d::CAPACITY_EXCEEDED;
    }
    if (try name = copy_serial_string(diagnostic.allocator, type_name)) {
        diagnostic.type_name = name;
    } else {
        clear_serial_diagnostic(diagnostic);
        diagnostic.cause = c3d::CAPACITY_EXCEEDED;
        return c3d::CAPACITY_EXCEEDED;
    }
    return cause;
}

fn fault asset_diagnostic(SerialDiagnostic* diagnostic, String key, fault cause) @private {
    if (!diagnostic) return cause;
    diagnostic.cause = cause;
    alloc::free(diagnostic.allocator, diagnostic.asset_key.ptr);
    diagnostic.asset_key = {};
    if (try copy = copy_serial_string(diagnostic.allocator, key)) {
        diagnostic.asset_key = copy;
        return cause;
    }
    clear_serial_diagnostic(diagnostic);
    diagnostic.cause = c3d::CAPACITY_EXCEEDED;
    return c3d::CAPACITY_EXCEEDED;
}
