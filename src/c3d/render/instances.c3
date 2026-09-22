module c3d::render;

import c3d;
import c3d::maths;
import c3d::scene;
import c3d::shader;
import gpu;
import std::collections::map;
import std::math;

<*
 Packed instance arrays written this frame, keyed by the stable batch node.
*>
struct InstanceCache {
    HashMap{ulong, gpu::GpuAddress} arrays;
}

<*
 Write one instance record from its world matrix and color.
 @param [&out] record : "Overwritten whole."
 @param world : "Affine instance matrix."
*>
fn void write_instance(InstanceGpu* record, Mat4 world, Vec4 color) {
    Mat3 normal = maths::normal_matrix(world);
    *record = {
        .model    = bitcast(world, Mat4f),
        .normal_0 = { normal.m00, normal.m10, normal.m20, 0 },
        .normal_1 = { normal.m01, normal.m11, normal.m21, 0 },
        .normal_2 = { normal.m02, normal.m12, normal.m22, 0 },
        .color    = color,
    };
}

<*
 Pack the live instances, unmirrored first, each group in array order.
 @param [out] records : "At least batch.count long."
 @param [&in] batch : "Live count above zero."
 @return "Index of the first mirrored record."
*>
fn uint pack_instance_records(InstanceGpu[] records, Mat4 node_world, InstancedMesh* batch) {
    uint written;
    foreach (index, transform : batch.transforms[:batch.count]) {
        if (scene::transform_mirrored(transform)) continue;
        write_instance(&records[written++], node_world.mul(transform.to_mat4()), batch.colors[index]);
    }
    uint split = written;
    foreach (index, transform : batch.transforms[:batch.count]) {
        if (!scene::transform_mirrored(transform)) continue;
        write_instance(&records[written++], node_world.mul(transform.to_mat4()), batch.colors[index]);
    }
    return split;
}

fn InstanceCache create_instance_cache(Allocator allocator) @private {
    InstanceCache cache;
    cache.arrays.init(allocator);
    return cache;
}

fn void destroy_instance_cache(InstanceCache* cache) @private {
    cache.arrays.free();
}

fn void reset_instance_cache(InstanceCache* cache) @private {
    cache.arrays.clear();
}

fn gpu::GpuAddress? resolve_instances(Renderer* renderer, MeshCandidate* candidate) @private {
    gpu::GpuAddress base;
    if (try existing = renderer.instances.arrays.get((ulong)(uptr)candidate.node)) {
        base = existing;
    } else {
        InstancedMesh* batch = candidate.batch;
        Frame* slot = &renderer.frames[renderer.frame_index % FRAMES_IN_FLIGHT];
        gpu::MappedGpuSpan span = slot.upload.take(
            device:    &renderer.device,
            size:      batch.count * InstanceGpu::size,
            alignment: STREAM_ALIGNMENT,
        )!;
        pack_instance_records(((InstanceGpu*)span.bytes.ptr)[:batch.count], candidate.node.world, batch);
        renderer.instances.arrays.set((ulong)(uptr)candidate.node, span.address);
        base = span.address;
    }
    return (gpu::GpuAddress)((ulong)base + (ulong)candidate.instance_first * InstanceGpu::size);
}
