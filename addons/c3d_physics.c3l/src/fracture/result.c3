module c3d::physics::fracture;

import c3d;
import std::math;

<* Borrow one connected solid in its translated piece frame. *>
struct FracturePieceView {
    SolidMeshView mesh;
    Vec3 origin;
}

<* Own independent fragment geometry and its borrowed piece table. *>
struct FractureResult {
    Allocator allocator;
    FracturePieceView[] pieces;
    char[] storage;
}

struct ResultLayout @local {
    char[] storage;
    usz used;
}

$assert Vec3::alignment <= FracturePieceView::alignment;
$assert Vec4::alignment <= FracturePieceView::alignment;
$assert Vec2::alignment <= FracturePieceView::alignment;
$assert uint::alignment <= FracturePieceView::alignment;

<*
 Release fragment storage and invalidate every piece view.
 @param [&inout] fragments : "Sole owning result."
*>
fn void destroy_fracture_result(FractureResult* fragments) {
    alloc::free_aligned(fragments.allocator, fragments.storage.ptr);
    *fragments = {};
}

fn usz? result_array_offset(
    ResultLayout* layout,
    usz count,
    usz stride,
    usz alignment,
) @local {
    usz padding = (alignment - layout.used % alignment) % alignment;
    usz remaining = (usz)sz::max - layout.used;
    if (padding > remaining || count > (remaining - padding) / stride) return c3d::CAPACITY_EXCEEDED~;
    usz offset = layout.used + padding;
    layout.used = offset + count * stride;
    return offset;
}

macro copy_result_array(ResultLayout* layout, $Type, values) @local {
    if (!values.len) return ($Type[]){};
    usz offset = result_array_offset(
        layout: layout,
        count: values.len,
        stride: $Type::size,
        alignment: $Type::alignment,
    )!;
    if (!layout.storage.ptr) return values;
    $Type[] copied = (($Type*)(layout.storage.ptr + offset))[:values.len];
    copied[..] = values[..];
    return copied;
}

fn FracturePieceView? copy_result_piece(ResultLayout* layout, FracturePieceView piece) @local {
    FracturePieceView copied = {
        .mesh = { .geometry = { .topology = piece.mesh.geometry.topology, .bounds = piece.mesh.geometry.bounds } },
        .origin = piece.origin,
    };
    copied.mesh.geometry.positions = copy_result_array(layout, Vec3, piece.mesh.geometry.positions)!;
    copied.mesh.geometry.normals = copy_result_array(layout, Vec3, piece.mesh.geometry.normals)!;
    copied.mesh.geometry.tangents = copy_result_array(layout, Vec4, piece.mesh.geometry.tangents)!;
    copied.mesh.geometry.uv0 = copy_result_array(layout, Vec2, piece.mesh.geometry.uv0)!;
    copied.mesh.geometry.uv1 = copy_result_array(layout, Vec2, piece.mesh.geometry.uv1)!;
    copied.mesh.geometry.colors = copy_result_array(layout, Vec4, piece.mesh.geometry.colors)!;
    copied.mesh.geometry.indices = copy_result_array(layout, uint, piece.mesh.geometry.indices)!;
    copied.mesh.topology_vertices = copy_result_array(layout, uint, piece.mesh.topology_vertices)!;
    copied.mesh.triangle_materials = copy_result_array(layout, uint, piece.mesh.triangle_materials)!;
    return copied;
}

fn FractureResult? copy_fracture_result(Allocator allocator, FracturePieceView[] pieces) @private {
    ResultLayout layout;
    (void)copy_result_array(&layout, FracturePieceView, pieces)!;
    foreach (piece : pieces) (void)copy_result_piece(&layout, piece)!;
    usz bytes = math::max(layout.used, (usz)1);
    char*? storage = alloc::calloc_aligned(allocator, (sz)bytes, FracturePieceView::alignment);
    if (catch storage) return c3d::CAPACITY_EXCEEDED~;
    FractureResult result = { .allocator = allocator, .storage = storage[:bytes] };
    defer catch destroy_fracture_result(&result);
    layout = { .storage = result.storage };
    result.pieces = copy_result_array(&layout, FracturePieceView, pieces)!;
    foreach (index, piece : pieces) result.pieces[index] = copy_result_piece(&layout, piece)!;
    return result;
}
