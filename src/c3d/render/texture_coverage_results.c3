module c3d::render;

import c3d;
import c3d::asset;
import c3d::material;

const ulong COVERAGE_SMALL_LEVEL_TEXELS @local = 64;
const uint WIDE_WORD_BITS @local = ulong::size * 8;
const double WIDE_WORD_UNIT @local = 0x1p64;

struct TextureCoverageCounts @private {
    ulong passing;
    ulong total;
    bool plateau;
}

struct TextureCoverageResource @private {
    Allocator allocator;
    uint revision;
    uint mip_count;
    uint face_count;
    bool committed;
    ulong[material::CUBE_FACE_COUNT] original_passing;
    ulong[material::CUBE_FACE_COUNT] original_total;
    TextureCoverageCounts[] counts;
}

$assert TextureCoverageResource::size % TextureCoverageCounts::alignment == 0;
$assert TextureCoverageCounts::alignment <= mem::DEFAULT_MEM_ALIGNMENT;

<*
 Inspect committed threshold coverage; small levels make no preservation claim.
 No committed threshold result faults ASSET_DATA_UNAVAILABLE.
 @param [&inout] self : "Renderer owning the committed resource."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT
 @return? c3d::ASSET_DATA_UNAVAILABLE
*>
fn TextureCoverageResult? Renderer.texture_coverage(
    &self,
    TextureId texture,
    uint mip,
    uint face = 0,
) {
    if (!self.assets.textures.is_live(texture)) return c3d::INVALID_ID~;

    if (try resource = committed_texture_coverage(self, texture)) {
        if (mip >= resource.mip_count || face >= resource.face_count) return c3d::INVALID_ARGUMENT~;

        return texture_coverage_result(resource, mip, face);
    }

    material::TextureDesc desc = self.assets.texture(texture).desc;

    if (!desc.width || !desc.height || !desc.layers) return c3d::ASSET_DATA_UNAVAILABLE~;

    uint mip_count = desc.generate_mips ? material::texture_mip_count(desc.width, desc.height) : desc.mip_levels;

    if (mip >= mip_count || face >= desc.layers) return c3d::INVALID_ARGUMENT~;

    return c3d::ASSET_DATA_UNAVAILABLE~;
}

fn TextureCoverageResource* create_texture_coverage_resource(
    Allocator allocator,
    material::TextureDesc desc,
    CoverageStatistics* statistics,
    uint revision,
) @private {
    uint mip_count = material::texture_mip_count(desc.width, desc.height);
    usz count = (usz)mip_count * desc.layers;
    char[] storage = alloc::new_array(allocator, char,
        (sz)(TextureCoverageResource::size + count * TextureCoverageCounts::size));
    TextureCoverageResource* resource = (TextureCoverageResource*)storage.ptr;

    *resource = {
        .allocator = allocator,
        .revision = revision,
        .mip_count = mip_count,
        .face_count = desc.layers,
        .original_passing = statistics.passing,
        .original_total = statistics.total,
        .counts = ((TextureCoverageCounts*)(storage.ptr + TextureCoverageResource::size))[:count],
    };

    for (uint face = 0; face < desc.layers; face++) {
        resource.counts[face] = { .passing = statistics.passing[face], .total = statistics.total[face] };
    }

    return resource;
}

fn void destroy_texture_coverage_resource(TextureCoverageResource* resource) @private {
    if (resource) alloc::free(resource.allocator, resource);
}

fn void store_texture_coverage_result(TextureCoverageResource* resource, TextureCoverageState* state) @private {
    if (!resource) return;
    resource.counts[(usz)state.mip * resource.face_count + state.face] = {
        .passing = state.expected,
        .total = state.texels,
        .plateau = state.plateau,
    };
}

fn TextureCoverageResult texture_coverage_result(TextureCoverageResource* resource, uint mip, uint face) @private {
    TextureCoverageCounts counts = resource.counts[(usz)mip * resource.face_count + face];
    ulong original_passing = resource.original_passing[face];
    ulong original_total = resource.original_total[face];
    uint128 actual = (uint128)counts.passing * original_total;
    uint128 target = (uint128)original_passing * counts.total;
    uint128 numerator = actual >= target ? actual - target : target - actual;
    uint128 denominator = (uint128)original_total * counts.total;
    double error = (double)(ulong)(numerator >> WIDE_WORD_BITS) * WIDE_WORD_UNIT + (double)(ulong)numerator;

    return {
        .revision = resource.revision,
        .original_passing = original_passing,
        .original_total = original_total,
        .passing = counts.passing,
        .total = counts.total,
        .error_numerator = numerator,
        .error_denominator = denominator,
        .absolute_error = error / ((double)original_total * (double)counts.total),
        .small_level = mip > 0 && counts.total < COVERAGE_SMALL_LEVEL_TEXELS,
        .plateau = counts.plateau,
    };
}

fn TextureCoverageResource*? committed_texture_coverage(Renderer* renderer, TextureId texture) @private {
    TextureRes* mirror = &renderer.textures[texture.index];

    if (c3d::same_id(mirror.asset, texture) && mirror.coverage_resource && mirror.coverage_resource.committed) {
        return mirror.coverage_resource;
    }

    foreach (install : renderer.pending_prepare_installs) {
        if (install.kind == PrepareUnitKind.TEXTURE && c3d::same_id(install.old_texture.asset, texture)
          && install.old_texture.coverage_resource && install.old_texture.coverage_resource.committed) {
            return install.old_texture.coverage_resource;
        }
    }

    foreach (pending : renderer.pending_texture_uploads) {
        if (c3d::same_id(pending.asset, texture) && pending.previous_coverage_resource
          && pending.previous_coverage_resource.committed) return pending.previous_coverage_resource;
    }

    return c3d::ASSET_DATA_UNAVAILABLE~;
}
