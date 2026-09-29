module c3d::asset;

import c3d;
import c3d::pool;

<*
 Scene snapshots a custom fragment stage samples; none with a gbuffer stage.
*>
bitstruct SceneReads : char {
    bool color : 0;
    bool depth : 1;
}

<*
 Shaded, depth and velocity forms of one user vertex stage.
 Pairs are whole; an instanced form needs its plain form, a velocity form its shaded one.
*>
struct CustomVertex {
    char[] shaded;
    char[] depth;
    char[] instanced_shaded;
    char[] instanced_depth;
    char[] velocity;
    char[] instanced_velocity;
}

<*
 Fragment forms drawn on views that trace shadows; either may be empty.
*>
struct TracedFragment {
    char[] hardware; // compiled with RT_SHADOWS; drawn on renderers with ray queries
    char[] software; // compiled with RT_SHADOWS and SCENE_TRACE_BVH; drawn without them
}

<*
 User SPIR-V stages, a fragment stage required, and their parameter payload size.
 An empty gbuffer stage routes the material forward on deferred views.
*>
struct ShaderDesc {
    char[]         fragment;
    char[]         gbuffer;
    TracedFragment traced_fragment;
    CustomVertex   vertex;
    usz            param_block_size;
    SceneReads     scene_reads;
}

<*
 Shader record; every byte array is owned by the store.
*>
struct ShaderAsset {
    AssetHeader header;
    ShaderDesc  desc;
}

<*
 Pool of shader records addressed by ShaderId.
*>
alias ShaderPool = Pool{ShaderAsset, ShaderId};

<*
 Add a shader, copying every stage into the store.
 @param [&in] desc : "Forms pair as the ShaderDesc and CustomVertex docs require."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn ShaderId? AssetStore.add_shader(&self, ShaderDesc* desc, String key = "") {
    check_key(self, key)!;
    check_shader_desc(desc)!;
    ShaderId id = self.shaders.add({})!;
    *self.shaders.get(id) = {
        .header = { .key = copy_string(self.allocator, key), .revision = 1 },
        .desc   = copy_shader_desc(self.allocator, desc),
    };
    register_key(self, key, typed_ref(AssetKind.SHADER, id));
    return id;
}

<*
 Record of the shader; a borrow into the pool.
 @require self.shaders.is_live(shader)
*>
fn ShaderAsset* AssetStore.shader(&self, ShaderId shader) {
    return self.shaders.get(shader);
}

<*
 Replace every stage with copies of the new ones and advance the revision.
 @param [&in] desc : "Forms pair as the ShaderDesc and CustomVertex docs require."
 @return? c3d::INVALID_ARGUMENT
 @require self.shaders.is_live(shader)
*>
fn void? AssetStore.replace_shader(&self, ShaderId shader, ShaderDesc* desc) {
    check_shader_desc(desc)!;
    ShaderAsset* record = self.shaders.get(shader);
    ShaderDesc copied = copy_shader_desc(self.allocator, desc);
    free_shader_desc(self.allocator, &record.desc);
    record.desc = copied;
    record.header.revision++;
    return;
}

<*
 Advance the content revision after an in-place edit of the copied bytes.
 @require self.shaders.is_live(shader)
*>
fn void AssetStore.mark_shader_dirty(&self, ShaderId shader) {
    self.shaders.get(shader).header.revision++;
}

<*
 Free the record and make its id stale.
 @require self.shaders.is_live(shader)
*>
fn void AssetStore.remove_shader(&self, ShaderId shader) {
    ShaderAsset* record = self.shaders.get(shader);
    forget_key(self, record.header.key);
    free_string(self.allocator, record.header.key);
    free_shader_desc(self.allocator, &record.desc);
    *record = {};
    self.shaders.remove(shader);
}

<*
 Shader id under a key.
 @return? NOT_FOUND, c3d::INVALID_ARGUMENT
*>
fn ShaderId? AssetStore.find_shader(&self, String key) {
    AssetRef found = self.find(key)!;
    if (found.kind != AssetKind.SHADER) return c3d::INVALID_ARGUMENT~;
    return (ShaderId){ .index = found.id.index, .generation = found.id.generation };
}

fn void? check_shader_desc(ShaderDesc* desc) @private {
    if (desc.fragment.len == 0) return c3d::INVALID_ARGUMENT~;
    CustomVertex* vertex = &desc.vertex;
    if ((vertex.shaded.len == 0) != (vertex.depth.len == 0)) return c3d::INVALID_ARGUMENT~;
    if ((vertex.instanced_shaded.len == 0) != (vertex.instanced_depth.len == 0)) return c3d::INVALID_ARGUMENT~;
    if (vertex.instanced_shaded.len && !vertex.shaded.len) return c3d::INVALID_ARGUMENT~;
    if (vertex.velocity.len && !vertex.shaded.len) return c3d::INVALID_ARGUMENT~;
    if (vertex.instanced_velocity.len && (!vertex.instanced_shaded.len || !vertex.velocity.len)) {
        return c3d::INVALID_ARGUMENT~;
    }
    if (desc.gbuffer.len && desc.scene_reads != (SceneReads){}) return c3d::INVALID_ARGUMENT~;
    return;
}

<*
 Copy of every stage in the allocator; an empty stage stays empty.
 @param [&in] desc
*>
fn ShaderDesc copy_shader_desc(Allocator allocator, ShaderDesc* desc) {
    return {
        .fragment = copy_slice(allocator, desc.fragment),
        .gbuffer = desc.gbuffer.len ? copy_slice(allocator, desc.gbuffer) : (char[]){},
        .traced_fragment = {
            .hardware = desc.traced_fragment.hardware.len
              ? copy_slice(allocator, desc.traced_fragment.hardware) : (char[]){},
            .software = desc.traced_fragment.software.len
              ? copy_slice(allocator, desc.traced_fragment.software) : (char[]){},
        },
        .vertex = {
            .shaded = desc.vertex.shaded.len ? copy_slice(allocator, desc.vertex.shaded) : (char[]){},
            .depth = desc.vertex.depth.len ? copy_slice(allocator, desc.vertex.depth) : (char[]){},
            .instanced_shaded = desc.vertex.instanced_shaded.len
              ? copy_slice(allocator, desc.vertex.instanced_shaded) : (char[]){},
            .instanced_depth = desc.vertex.instanced_depth.len
              ? copy_slice(allocator, desc.vertex.instanced_depth) : (char[]){},
            .velocity = desc.vertex.velocity.len ? copy_slice(allocator, desc.vertex.velocity) : (char[]){},
            .instanced_velocity = desc.vertex.instanced_velocity.len
              ? copy_slice(allocator, desc.vertex.instanced_velocity) : (char[]){},
        },
        .param_block_size = desc.param_block_size,
        .scene_reads = desc.scene_reads,
    };
}

<*
 Free every stage allocated with the allocator.
 @param [&inout] desc : "Left zeroed."
*>
fn void free_shader_desc(Allocator allocator, ShaderDesc* desc) {
    alloc::free(allocator, desc.fragment.ptr);
    alloc::free(allocator, desc.gbuffer.ptr);
    alloc::free(allocator, desc.traced_fragment.hardware.ptr);
    alloc::free(allocator, desc.traced_fragment.software.ptr);
    alloc::free(allocator, desc.vertex.shaded.ptr);
    alloc::free(allocator, desc.vertex.depth.ptr);
    alloc::free(allocator, desc.vertex.instanced_shaded.ptr);
    alloc::free(allocator, desc.vertex.instanced_depth.ptr);
    alloc::free(allocator, desc.vertex.velocity.ptr);
    alloc::free(allocator, desc.vertex.instanced_velocity.ptr);
    *desc = {};
}
