module c3d::asset;

import c3d;
import c3d::material;
import c3d::pool;

<*
 Texture record: description plus mip-0 pixels in layer order.
*>
struct TextureAsset {
    AssetHeader header;
    TextureDesc desc;
    char[]      pixels;
}

<*
 Pool of texture records addressed by TextureId.
*>
alias TexturePool = Pool{TextureAsset, TextureId};

<*
 Add a texture, copying the pixels into the store.
 @param pixels : "Mip-0 texels, every layer in layer order."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn TextureId? AssetStore.add_texture(&self, TextureDesc desc, char[] pixels, String key = "") {
    check_key(self, key)!;
    TextureId id = self.textures.add({})!;
    *self.textures.get(id) = {
        .header = { .key = copy_string(self.allocator, key), .revision = 1 },
        .desc   = desc,
        .pixels = copy_slice(self.allocator, pixels),
    };
    register_key(self, key, typed_ref(AssetKind.TEXTURE, id));
    return id;
}

<*
 Add a texture whose pixels the store takes over on success.
 @param pixels : "Mip-0 texels in layer order, allocated with the store allocator."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn TextureId? AssetStore.add_texture_owned(&self, TextureDesc desc, char[] pixels, String key = "") {
    check_key(self, key)!;
    TextureId id = self.textures.add({})!;
    *self.textures.get(id) = {
        .header = { .key = copy_string(self.allocator, key), .revision = 1 },
        .desc   = desc,
        .pixels = pixels,
    };
    register_key(self, key, typed_ref(AssetKind.TEXTURE, id));
    return id;
}

<*
 Record of the texture; a borrow into the pool.
 @require self.textures.is_live(texture)
*>
fn TextureAsset* AssetStore.texture(&self, TextureId texture) {
    return self.textures.get(texture);
}

<*
 Advance the content revision after an edit.
 @require self.textures.is_live(texture)
*>
fn void AssetStore.mark_texture_dirty(&self, TextureId texture) {
    self.textures.get(texture).header.revision++;
}

<*
 Free the pixels; keep the description, id, and revision.
 @require self.textures.is_live(texture)
*>
fn void AssetStore.release_texture_cpu(&self, TextureId texture) {
    TextureAsset* record = self.textures.get(texture);
    alloc::free(self.allocator, record.pixels.ptr);
    record.pixels = {};
}

<*
 Free the record and make its id stale.
 @require self.textures.is_live(texture), texture.index >= BUILTIN_TEXTURE_COUNT
*>
fn void AssetStore.remove_texture(&self, TextureId texture) {
    TextureAsset* record = self.textures.get(texture);
    forget_key(self, record.header.key);
    free_string(self.allocator, record.header.key);
    alloc::free(self.allocator, record.pixels.ptr);
    *record = {};
    self.textures.remove(texture);
}
