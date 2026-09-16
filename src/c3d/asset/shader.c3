module c3d::asset;

import c3d;
import c3d::pool;

<*
 Shaded and depth-only forms of one user vertex stage; both or neither.
*>
struct CustomVertex {
    char[] shaded;
    char[] depth;
}

<*
 User SPIR-V stages and the byte size of their parameter payload.
*>
struct ShaderDesc {
    char[]       fragment;
    CustomVertex vertex;
    usz          param_block_size;
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
 @param [&in] desc : "Fragment non-empty; vertex stages both or neither."
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
 @param [&in] desc : "Fragment non-empty; vertex stages both or neither."
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
    if ((desc.vertex.shaded.len == 0) != (desc.vertex.depth.len == 0)) return c3d::INVALID_ARGUMENT~;
    return;
}

fn ShaderDesc copy_shader_desc(Allocator allocator, ShaderDesc* desc) @private {
    return {
        .fragment = copy_slice(allocator, desc.fragment),
        .vertex = {
            .shaded = desc.vertex.shaded.len ? copy_slice(allocator, desc.vertex.shaded) : (char[]){},
            .depth = desc.vertex.depth.len ? copy_slice(allocator, desc.vertex.depth) : (char[]){},
        },
        .param_block_size = desc.param_block_size,
    };
}

fn void free_shader_desc(Allocator allocator, ShaderDesc* desc) @private {
    alloc::free(allocator, desc.fragment.ptr);
    alloc::free(allocator, desc.vertex.shaded.ptr);
    alloc::free(allocator, desc.vertex.depth.ptr);
    *desc = {};
}
