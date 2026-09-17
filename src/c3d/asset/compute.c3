module c3d::asset;

import c3d;
import c3d::pool;

<*
 User SPIR-V compute stage.
*>
struct ComputeShaderDesc {
    char[] compute;
}

<*
 Compute shader record; the byte array is owned by the store.
*>
struct ComputeShaderAsset {
    AssetHeader       header;
    ComputeShaderDesc desc;
}

<*
 Pool of compute shader records addressed by ComputeShaderId.
*>
alias ComputeShaderPool = Pool{ComputeShaderAsset, ComputeShaderId};

<*
 Add a compute shader, copying its stage into the store.
 @param [&in] desc : "Stage non-empty."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn ComputeShaderId? AssetStore.add_compute_shader(&self, ComputeShaderDesc* desc, String key = "") {
    check_key(self, key)!;
    check_compute_shader_desc(desc)!;
    ComputeShaderId id = self.compute_shaders.add({})!;
    *self.compute_shaders.get(id) = {
        .header = { .key = copy_string(self.allocator, key), .revision = 1 },
        .desc   = { .compute = copy_slice(self.allocator, desc.compute) },
    };
    register_key(self, key, typed_ref(AssetKind.COMPUTE_SHADER, id));
    return id;
}

<*
 Record of the compute shader; a borrow into the pool.
 @require self.compute_shaders.is_live(shader)
*>
fn ComputeShaderAsset* AssetStore.compute_shader(&self, ComputeShaderId shader) {
    return self.compute_shaders.get(shader);
}

<*
 Replace the stage with a copy of the new one and advance the revision.
 @param [&in] desc : "Stage non-empty."
 @return? c3d::INVALID_ARGUMENT
 @require self.compute_shaders.is_live(shader)
*>
fn void? AssetStore.replace_compute_shader(&self, ComputeShaderId shader, ComputeShaderDesc* desc) {
    check_compute_shader_desc(desc)!;
    ComputeShaderAsset* record = self.compute_shaders.get(shader);
    char[] copied = copy_slice(self.allocator, desc.compute);
    alloc::free(self.allocator, record.desc.compute.ptr);
    record.desc.compute = copied;
    record.header.revision++;
    return;
}

<*
 Advance the content revision after an in-place edit of the copied bytes.
 @require self.compute_shaders.is_live(shader)
*>
fn void AssetStore.mark_compute_shader_dirty(&self, ComputeShaderId shader) {
    self.compute_shaders.get(shader).header.revision++;
}

<*
 Free the record and make its id stale.
 @require self.compute_shaders.is_live(shader)
*>
fn void AssetStore.remove_compute_shader(&self, ComputeShaderId shader) {
    ComputeShaderAsset* record = self.compute_shaders.get(shader);
    forget_key(self, record.header.key);
    free_string(self.allocator, record.header.key);
    alloc::free(self.allocator, record.desc.compute.ptr);
    *record = {};
    self.compute_shaders.remove(shader);
}

<*
 Compute shader id under a key.
 @return? NOT_FOUND, c3d::INVALID_ARGUMENT
*>
fn ComputeShaderId? AssetStore.find_compute_shader(&self, String key) {
    AssetRef found = self.find(key)!;
    if (found.kind != AssetKind.COMPUTE_SHADER) return c3d::INVALID_ARGUMENT~;
    return (ComputeShaderId){ .index = found.id.index, .generation = found.id.generation };
}

fn void? check_compute_shader_desc(ComputeShaderDesc* desc) @private {
    if (desc.compute.len == 0) return c3d::INVALID_ARGUMENT~;
    return;
}
