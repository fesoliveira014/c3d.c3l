module c3d::asset;

import c3d;
import c3d::anim;
import c3d::pool;

<*
 Skeleton record.
*>
struct SkeletonAsset {
    AssetHeader header;
    Skeleton    data;
}

<*
 Pool of skeleton records addressed by SkeletonId.
*>
alias SkeletonPool = Pool{SkeletonAsset, SkeletonId};

<*
 Add a skeleton whose arrays the store takes over on success.
 @param [&in] skeleton : "Arrays and names were allocated with the store allocator."
 @return? c3d::CAPACITY_EXCEEDED, c3d::INVALID_ARGUMENT
*>
fn SkeletonId? AssetStore.add_skeleton_owned(&self, Skeleton* skeleton, String key = "") {
    check_key(self, key)!;
    SkeletonId id = self.skeletons.add({})!;
    *self.skeletons.get(id) = {
        .header = { .key = copy_string(self.allocator, key), .revision = 1 },
        .data   = *skeleton,
    };
    register_key(self, key, typed_ref(AssetKind.SKELETON, id));
    return id;
}

<*
 Record of the skeleton; a borrow into the pool.
 @require self.skeletons.is_live(skeleton)
*>
fn SkeletonAsset* AssetStore.skeleton(&self, SkeletonId skeleton) {
    return self.skeletons.get(skeleton);
}

<*
 Free the record and make its id stale.
 @require self.skeletons.is_live(skeleton)
*>
fn void AssetStore.remove_skeleton(&self, SkeletonId skeleton) {
    SkeletonAsset* record = self.skeletons.get(skeleton);
    forget_key(self, record.header.key);
    free_string(self.allocator, record.header.key);
    free_skeleton(self.allocator, &record.data);
    *record = {};
    self.skeletons.remove(skeleton);
}

<*
 Skeleton id under a key.
 @return? NOT_FOUND, c3d::INVALID_ARGUMENT
*>
fn SkeletonId? AssetStore.find_skeleton(&self, String key) {
    AssetRef found = self.find(key)!;
    if (found.kind != AssetKind.SKELETON) return c3d::INVALID_ARGUMENT~;
    return (SkeletonId){ .index = found.id.index, .generation = found.id.generation };
}

<*
 Free every array and name of a skeleton allocated with the allocator.
 @param [&inout] skeleton : "Left zeroed."
*>
fn void free_skeleton(Allocator allocator, Skeleton* skeleton) {
    foreach (name : skeleton.joint_names) alloc::free(allocator, name.ptr);
    alloc::free(allocator, skeleton.joint_names.ptr);
    alloc::free(allocator, skeleton.parents.ptr);
    alloc::free(allocator, skeleton.rest_pose.ptr);
    alloc::free(allocator, skeleton.inverse_bind.ptr);
    *skeleton = {};
}
