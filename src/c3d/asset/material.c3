module c3d::asset;

import c3d;
import c3d::material;
import c3d::pool;

<*
 Material record.
*>
struct MaterialAsset {
    AssetHeader header;
    Material    data;
}

<*
 Pool of material records addressed by MaterialId.
*>
alias MaterialPool = Pool{MaterialAsset, MaterialId};

<*
 Add a material; a custom payload is copied into the store.
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn MaterialId? AssetStore.add_material(&self, Material material, String key = "") {
    check_key(self, key)!;
    MaterialId id = self.materials.add({})!;
    if (material.kind == MaterialKind.CUSTOM && material.custom.param_block.len) {
        material.custom.param_block = copy_slice(self.allocator, material.custom.param_block);
    }
    *self.materials.get(id) = {
        .header = { .key = copy_string(self.allocator, key), .revision = 1 },
        .data   = material,
    };
    register_key(self, key, typed_ref(AssetKind.MATERIAL, id));
    return id;
}

<*
 Record of the material; a borrow into the pool.
 @require self.materials.is_live(material)
*>
fn MaterialAsset* AssetStore.material(&self, MaterialId material) {
    return self.materials.get(material);
}

<*
 Advance the content revision after an edit.
 @require self.materials.is_live(material)
*>
fn void AssetStore.mark_material_dirty(&self, MaterialId material) {
    self.materials.get(material).header.revision++;
}

<*
 Free the record and make its id stale.
 @require self.materials.is_live(material)
*>
fn void AssetStore.remove_material(&self, MaterialId material) {
    MaterialAsset* record = self.materials.get(material);
    forget_key(self, record.header.key);
    free_string(self.allocator, record.header.key);
    free_custom_params(self.allocator, &record.data);
    *record = {};
    self.materials.remove(material);
}

<*
 Replace the payload bytes of a custom material and advance its revision.
 @param bytes : "Copied; may change the payload length."
 @return? c3d::INVALID_ARGUMENT
 @require self.materials.is_live(material)
*>
fn void? AssetStore.set_custom_params(&self, MaterialId material, char[] bytes) {
    MaterialAsset* record = self.materials.get(material);
    if (record.data.kind != MaterialKind.CUSTOM) return c3d::INVALID_ARGUMENT~;
    char[]* block = &record.data.custom.param_block;
    if (block.len != bytes.len) {
        alloc::free(self.allocator, block.ptr);
        *block = bytes.len ? alloc::new_array(self.allocator, char, bytes.len) : (char[]){};
    }
    if (bytes.len) (*block)[..] = bytes[..];
    record.header.revision++;
    return;
}

<*
 Replace the payload with the bytes of a value and advance the revision.
 @return? c3d::INVALID_ARGUMENT
 @require self.materials.is_live(material)
*>
macro void? AssetStore.@set_custom_params(&self, MaterialId material, #value) {
    return self.set_custom_params(material, material::@as_bytes(#value));
}

<*
 Typed view of the payload for in-place edits followed by mark_material_dirty.
 @require self.materials.is_live(material), self.material(material).data.kind == MaterialKind.CUSTOM
 @require $Type::size == self.material(material).data.custom.param_block.len
*>
macro AssetStore.@custom_params(&self, MaterialId material, $Type) {
    return ($Type*)self.material(material).data.custom.param_block.ptr;
}

fn void free_custom_params(Allocator allocator, Material* material) @private {
    if (material.kind != MaterialKind.CUSTOM) return;
    alloc::free(allocator, material.custom.param_block.ptr);
    material.custom.param_block = {};
}
