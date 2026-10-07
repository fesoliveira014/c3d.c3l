module c3d::physics::fracture;

import c3d;
import std::math;

<* Fixed exact-arithmetic block; generation storage is additional. *>
const usz MIN_FRACTURE_SCRATCH_BYTES = ExactScratch::size; // 24,880 bytes, 1032 per 8192-bit value; reserves arithmetic once

<* Bound working storage, output size and geometric resolution. *>
struct FractureLimits {
    usz scratch_bytes;
    uint max_vertices;
    uint max_triangles;
    uint max_pieces;
    uint max_sites;
    uint max_hulls;
    float resolution_m;
}

<* Own reusable storage for one exclusive fracture operation. *>
struct FractureWorkspace {
    Allocator allocator;
    FractureLimits limits;
    char[] storage;
}

<*
 Allocate a bounded reusable fracture workspace.
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn FractureWorkspace? create_fracture_workspace(Allocator allocator, FractureLimits limits) {
    if (limits.scratch_bytes < MIN_FRACTURE_SCRATCH_BYTES || !limits.max_vertices || !limits.max_triangles
        || !limits.max_pieces || !limits.max_sites || !limits.max_hulls
        || !(limits.resolution_m > 0 && math::is_finite(limits.resolution_m))) return c3d::INVALID_ARGUMENT~;
    if (limits.scratch_bytes > (usz)sz::max) return c3d::CAPACITY_EXCEEDED~;
    char*? storage = alloc::calloc_aligned(allocator, (sz)limits.scratch_bytes, ExactScratch::alignment);
    if (catch storage) return c3d::CAPACITY_EXCEEDED~;
    return {
        .allocator = allocator,
        .limits = limits,
        .storage = storage[:limits.scratch_bytes],
    };
}

<*
 Release all workspace storage.
 @param [&inout] workspace : "Sole owner; no operation is active."
*>
fn void destroy_fracture_workspace(FractureWorkspace* workspace) {
    alloc::free_aligned(workspace.allocator, workspace.storage.ptr);
    *workspace = {};
}
