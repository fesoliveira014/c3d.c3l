module c3d::asset;

import c3d;
import c3d::material;
import c3d::pool;

<*
 Pool of texture records addressed by TextureId.
*>
alias TexturePool = Pool{TextureAsset, TextureId};

<* Source representation retained by a texture asset. *>
enum TextureSourceKind {
    MIP_ZERO,
    SUPPLIED_MIPS,
}

<* One complete mip of one layer; input bytes are borrowed. *>
struct TextureMipData {
    uint mip;
    uint layer;
    char[] bytes;
}

$assert TextureMipData::alignment <= mem::DEFAULT_MEM_ALIGNMENT;
$assert TextureMipData::size % float::alignment == 0;

<*
 Texture metadata and its one selected CPU source representation.
*>
struct TextureAsset {
    AssetHeader header;
    TextureDesc desc;
    TextureSourceKind source_kind;
    char[] pixels;
    TextureMipData[] supplied_mips;
}

<*
 Add a texture, copying the pixels into the store.
 @param [&inout] self : "Owns copied pixels on successful insertion."
 @param pixels : "Mip-0 texels, every layer in layer order."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn TextureId? AssetStore.add_texture(
    &self,
    TextureDesc desc,
    char[] pixels,
    String key = "",
) {
    check_key(self, key)!;
    TextureId id = self.textures.add({})!;
    *self.textures.get(id) = {
        .header = { .key = copy_string(self.allocator, key), .revision = 1 },
        .desc = desc,
        .source_kind = MIP_ZERO,
        .pixels = copy_slice(self.allocator, pixels),
    };
    register_key(self, key, typed_ref(AssetKind.TEXTURE, id));

    return id;
}

<*
 Add a texture, taking ownership of its pixels on success.
 @param [&inout] self : "Owns transferred pixels on successful insertion."
 @param pixels : "Mip-zero layers allocated with the store allocator."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn TextureId? AssetStore.add_texture_owned(
    &self,
    TextureDesc desc,
    char[] pixels,
    String key = "",
) {
    check_key(self, key)!;
    TextureId id = self.textures.add({})!;
    *self.textures.get(id) = {
        .header = { .key = copy_string(self.allocator, key), .revision = 1 },
        .desc = desc,
        .source_kind = MIP_ZERO,
        .pixels = pixels,
    };
    register_key(self, key, typed_ref(AssetKind.TEXTURE, id));

    return id;
}

<*
 Add supplied mips, copying records and bytes into the store.
 @param [&inout] self : "Owns one source allocation on successful insertion."
 @param levels : "Complete slices ordered mip-major, then layer."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn TextureId? AssetStore.add_texture_mips(
    &self,
    TextureDesc desc,
    TextureMipData[] levels,
    String key = "",
) {
    check_key(self, key)!;
    if (!desc.mip_levels || !desc.layers || desc.generate_mips) return c3d::INVALID_ARGUMENT~;
    if ((ulong)desc.mip_levels * desc.layers != levels.len) return c3d::INVALID_ARGUMENT~;
    if (levels.len > (usz)sz::max / TextureMipData::size) return c3d::INVALID_ARGUMENT~;

    usz record_bytes = levels.len * TextureMipData::size;
    usz total_bytes = record_bytes;
    foreach (index, level : levels) {
        if (level.mip != index / desc.layers || level.layer != index % desc.layers || !level.bytes.len) {
            return c3d::INVALID_ARGUMENT~;
        }
        if (level.bytes.len > (usz)sz::max - total_bytes) return c3d::INVALID_ARGUMENT~;
        total_bytes += level.bytes.len;
    }

    TextureId texture = self.textures.add({})!;
    char[] storage = alloc::new_array(self.allocator, char, (sz)total_bytes);
    TextureMipData[] copied = ((TextureMipData*)storage.ptr)[:levels.len];
    usz offset = record_bytes;
    foreach (index, level : levels) {
        char[] bytes = storage[offset:level.bytes.len];
        mem::copy(bytes.ptr, level.bytes.ptr, bytes.len);
        copied[index] = { .mip = level.mip, .layer = level.layer, .bytes = bytes };
        offset += bytes.len;
    }

    *self.textures.get(texture) = {
        .header = { .key = copy_string(self.allocator, key), .revision = 1 },
        .desc = desc,
        .source_kind = SUPPLIED_MIPS,
        .supplied_mips = copied,
    };
    register_key(self, key, typed_ref(AssetKind.TEXTURE, texture));

    return texture;
}

<*
 Record of the texture; a borrow into the pool.
 @param [&inout] self : "Store owning the borrowed record."
 @require self.textures.is_live(texture)
*>
fn TextureAsset* AssetStore.texture(&self, TextureId texture) {
    return self.textures.get(texture);
}

<*
 Advance the content revision after an edit.
 @param [&inout] self : "Store whose texture revision advances."
 @require self.textures.is_live(texture)
*>
fn void AssetStore.mark_texture_dirty(&self, TextureId texture) {
    self.textures.get(texture).header.revision++;
}

<*
 Release CPU source; preserve description, id, revision and source kind.
 @param [&inout] self : "Store whose texture source is released."
 @require self.textures.is_live(texture)
*>
fn void AssetStore.release_texture_cpu(&self, TextureId texture) {
    TextureAsset* record = self.textures.get(texture);
    free_texture_source(self.allocator, record);
}

<*
 Free the record and make its id stale.
 @param [&inout] self : "Store whose texture and source are removed."
 @require self.textures.is_live(texture), texture.index >= BUILTIN_TEXTURE_COUNT
*>
fn void AssetStore.remove_texture(&self, TextureId texture) {
    TextureAsset* record = self.textures.get(texture);
    forget_key(self, record.header.key);
    free_string(self.allocator, record.header.key);
    free_texture_source(self.allocator, record);
    *record = {};
    self.textures.remove(texture);
}

fn void free_texture_source(Allocator allocator, TextureAsset* record) @private {
    switch (record.source_kind) {
        case MIP_ZERO: alloc::free(allocator, record.pixels.ptr);
        case SUPPLIED_MIPS: alloc::free(allocator, record.supplied_mips.ptr);
    }

    record.pixels = {};
    record.supplied_mips = {};
}
