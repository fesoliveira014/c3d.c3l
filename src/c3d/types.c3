module c3d;

typedef GeometryId     = Id;
typedef TextureId      = Id;
typedef SamplerId      = Id;
typedef MaterialId     = Id;
typedef EnvironmentId  = Id;
typedef SkinId         = Id;
typedef ShaderId       = Id;
typedef ModelId        = Id;
typedef ClipId         = Id;
typedef SkeletonId     = Id;
typedef ViewId         = Id;
typedef RenderTargetId = Id;

// ViewId and RenderTargetId are renderer-owned and cannot be found in the store, so they have no kind.
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
