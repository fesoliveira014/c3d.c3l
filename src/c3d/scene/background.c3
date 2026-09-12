module c3d::scene;

import c3d;
import std::math;

<* Opaque black background with identity environment settings. *>
const Background BACKGROUND_DEFAULT = {
    .kind = BackgroundKind.COLOR,
    .color = { 0, 0, 0, 1 },
    .intensity = 1,
    .rotation = quaternion::IDENTITY,
};

<* Source displayed behind scene geometry. *>
enum BackgroundKind {
    COLOR,
    ENVIRONMENT,
}

<* Background selection independent of scene illumination. *>
struct Background {
    BackgroundKind kind;
    Vec4 color;
    EnvironmentId environment;
    float intensity;
    Quat rotation;
}
