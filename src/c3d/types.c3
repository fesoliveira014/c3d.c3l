module c3d;

<*
 Generational handle into a pool. The zero value is never live.
*>
struct Id
{
    uint index;
    uint generation;
}

typedef GeometryId    = Id;
typedef TextureId     = Id;
typedef SamplerId     = Id;
typedef MaterialId    = Id;
typedef EnvironmentId = Id;
typedef SkinId        = Id;
typedef ShaderId      = Id;
