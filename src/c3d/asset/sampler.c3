module c3d::asset;

import c3d;
import c3d::material;
import c3d::pool;

<*
 Sampler record.
*>
struct SamplerAsset {
    AssetHeader header;
    SamplerDesc desc;
}

<*
 Pool of sampler records addressed by SamplerId.
*>
alias SamplerPool = Pool{SamplerAsset, SamplerId};

<*
 Add a sampler description.
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn SamplerId? AssetStore.add_sampler(&self, SamplerDesc desc, String key = "") {
    check_key(self, key)!;
    SamplerId id = self.samplers.add({})!;
    *self.samplers.get(id) = {
        .header = { .key = copy_string(self.allocator, key), .revision = 1 },
        .desc   = desc,
    };
    register_key(self, key, typed_ref(AssetKind.SAMPLER, id));
    return id;
}

<*
 Record of the sampler; a borrow into the pool.
 @require self.samplers.is_live(sampler)
*>
fn SamplerAsset* AssetStore.sampler(&self, SamplerId sampler) {
    return self.samplers.get(sampler);
}

<*
 Advance the content revision after an edit.
 @require self.samplers.is_live(sampler)
*>
fn void AssetStore.mark_sampler_dirty(&self, SamplerId sampler) {
    self.samplers.get(sampler).header.revision++;
}

<*
 Free the record and make its id stale.
 @require self.samplers.is_live(sampler)
*>
fn void AssetStore.remove_sampler(&self, SamplerId sampler) {
    SamplerAsset* record = self.samplers.get(sampler);
    forget_key(self, record.header.key);
    free_string(self.allocator, record.header.key);
    *record = {};
    self.samplers.remove(sampler);
}
