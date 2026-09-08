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
 Add a material.
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn MaterialId? AssetStore.add_material(&self, Material material, String key = "") {
    check_key(self, key)!;
    MaterialId id = self.materials.add({})!;
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
    *record = {};
    self.materials.remove(material);
}
