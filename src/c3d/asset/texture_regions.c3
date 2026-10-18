module c3d::asset;

import c3d;
import c3d::material;
import std::math;

<*
 Region marks a texture remembers.
*>
const uint TEXTURE_REGION_MARKS = 4; // 136 B per texture; a reader further behind uploads the texture whole

<*
 Change of a texture since a revision.
*>
enum TextureChange {
    NONE,
    REGIONS,
    WHOLE,
}

<*
 Texel box of one mip level; z and depth count slices of a 3D texture or layers of an array.
*>
struct TextureRegion {
    uint x;
    uint y;
    uint z;
    uint width;
    uint height;
    uint depth;
}

<*
 Region a mark edited, its mip and the texture revision the mark produced.
*>
struct TextureRegionMark {
    uint          revision;
    uint          mip;
    TextureRegion region;
}

<*
 Recent region marks of a texture, oldest first; any other revision advance empties it.
*>
struct TextureRegionLog {
    uint                                    base_revision; // revision before the first mark; read only while count > 0
    uint                                    count;
    TextureRegionMark[TEXTURE_REGION_MARKS] marks;
}

<*
 Region covering both.
 @pure
*>
fn TextureRegion TextureRegion.merge(self, TextureRegion other) {
    uint first_x = math::min(self.x, other.x);
    uint first_y = math::min(self.y, other.y);
    uint first_z = math::min(self.z, other.z);
    uint end_x = math::max(self.x + self.width, other.x + other.width);
    uint end_y = math::max(self.y + self.height, other.y + other.height);
    uint end_z = math::max(self.z + self.depth, other.z + other.depth);

    return {
        .x      = first_x,
        .y      = first_y,
        .z      = first_z,
        .width  = end_x - first_x,
        .height = end_y - first_y,
        .depth  = end_z - first_z,
    };
}

<*
 Record a mark, merging or dropping the oldest mark when the log is full.
 @param base_revision : "Texture revision before the mark; kept only when the log was empty."
*>
fn void TextureRegionLog.append(&self, uint base_revision, TextureRegionMark mark) {
    if (!self.count) self.base_revision = base_revision;

    if (self.count == TEXTURE_REGION_MARKS) {
        if (self.marks[0].mip == self.marks[1].mip) {
            self.marks[1].region = self.marks[0].region.merge(self.marks[1].region);
        } else {
            self.base_revision = self.marks[0].revision;
        }

        for (uint index = 1; index < self.count; index++) self.marks[index - 1] = self.marks[index];

        self.count--;
    }

    self.marks[self.count++] = mark;
}

<*
 Mip levels a region mark may name; zero when the source holds no texels.
*>
fn uint TextureAsset.region_mip_count(&self) {
    switch (self.source_kind) {
        case MIP_ZERO: return 1;
        case SUPPLIED_MIPS: return self.desc.mip_levels;
        case EMPTY: return 0;
    }
}

<*
 Change of the texture since a revision, as one region union per mip.
 @param [out] per_mip : "One region per markable mip; an unchanged mip gets width 0."
 @require per_mip.len >= self.region_mip_count()
 @return "WHOLE when the log does not reach back to the revision."
*>
fn TextureChange TextureAsset.regions_since(&self, uint revision, TextureRegion[] per_mip) {
    if (revision == self.header.revision) return NONE;
    if (!self.regions.count || revision < self.regions.base_revision) return WHOLE;

    uint first_after = self.regions.count;
    foreach (index, mark : self.regions.marks[:self.regions.count]) {
        if (mark.revision > revision) {
            first_after = (uint)index;
            break;
        }
    }

    if (first_after == self.regions.count) return WHOLE;

    foreach (&region : per_mip[:self.region_mip_count()]) *region = {};

    foreach (mark : self.regions.marks[first_after:self.regions.count - first_after]) {
        TextureRegion* union_region = &per_mip[mark.mip];
        *union_region = union_region.width ? union_region.merge(mark.region) : mark.region;
    }

    return REGIONS;
}

<*
 Mark texels of one mip level changed and advance the texture's revision.
 @param [&inout] self : "Store whose texture revision advances."
 @require region.width > 0 && region.height > 0 && region.depth > 0
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
*>
fn void? AssetStore.mark_texture_region_dirty(&self, TextureId texture, uint mip, TextureRegion region) {
    if (!self.textures.is_live(texture)) return c3d::INVALID_ID~;

    TextureAsset* record = self.textures.get(texture);
    check_texture_region(record, mip, region)!;

    uint base_revision = record.header.revision;
    record.header.revision++;
    record.regions.append(
        base_revision,
        { .revision = record.header.revision, .mip = mip, .region = region },
    );
}

fn void? check_texture_region(TextureAsset* record, uint mip, TextureRegion region) @local {
    if (mip >= record.region_mip_count()) return c3d::INVALID_ARGUMENT~;

    TextureDesc* desc = &record.desc;
    uint extent_z = desc.depth ? material::texture_mip_extent(desc.depth, mip) : math::max(desc.layers, 1u);

    if ((ulong)region.x + region.width > material::texture_mip_extent(desc.width, mip)
      || (ulong)region.y + region.height > material::texture_mip_extent(desc.height, mip)
      || (ulong)region.z + region.depth > extent_z) {
        return c3d::INVALID_ARGUMENT~;
    }
}
