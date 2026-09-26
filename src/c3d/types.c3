module c3d;

typedef GeometryId     = Id;
typedef TextureId      = Id;
typedef SamplerId      = Id;
typedef MaterialId     = Id;
typedef EnvironmentId  = Id;
typedef SkinId         = Id;
typedef ShaderId       = Id;
typedef ComputeShaderId = Id;
typedef ModelId        = Id;
typedef ClipId         = Id;
typedef SkeletonId     = Id;
typedef ViewId         = Id;
typedef RenderTargetId = Id;
typedef BufferId       = Id;

// ViewId, RenderTargetId and BufferId are renderer-owned and cannot be found in the store, so they have no kind.
<*
 Asset kinds the store resolves by id.
*>
enum AssetKind {
    GEOMETRY,
    TEXTURE,
    SAMPLER,
    MATERIAL,
    MODEL,
    CLIP,
    SKELETON,
    SHADER,
    COMPUTE_SHADER,
    ENVIRONMENT,
}

<*
 Generational handle into a pool. The zero value is never live.
*>
struct Id {
    uint index;
    uint generation;
}

<*
 Asset id carrying its kind, for results that cross asset kinds.
*>
struct AssetRef {
    AssetKind kind;
    Id        id;
}

<*
 Whether both handles name the same slot and generation.
 @require $Typeof(first) == $Typeof(second) : "Both handles have the same id type."
*>
macro bool same_id(first, second) => first.index == second.index && first.generation == second.generation;
