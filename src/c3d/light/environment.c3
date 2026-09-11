module c3d::light;

import c3d;
import std::math;

<* Default face sizes for source conversion and specular filtering. *>
const EnvironmentSettings ENVIRONMENT_SETTINGS_DEFAULT = {
    .conversion_size = 512,
    .specular_size = 256,
}; // About 16 MiB of generated cubes for an equirectangular source.

<* Source representation of an environment. *>
enum EnvironmentSourceKind {
    TEXTURE,
    SOLID,
}

<* Face-edge dimensions for environment processing, in texels. *>
struct EnvironmentSettings {
    uint conversion_size;
    uint specular_size;
}

<* Source and processing settings for image-based lighting. *>
struct EnvironmentDesc {
    EnvironmentSourceKind kind;
    TextureId source;
    Vec3 solid_color;
    EnvironmentSettings settings;
}

<* Describe an environment borrowing a texture asset. *>
fn EnvironmentDesc texture_environment(
    TextureId source,
    EnvironmentSettings settings = ENVIRONMENT_SETTINGS_DEFAULT,
) {
    return {
        .kind = EnvironmentSourceKind.TEXTURE,
        .source = source,
        .settings = settings,
    };
}

<* Describe a uniform scene-linear environment. *>
fn EnvironmentDesc solid_environment(
    Vec3 color,
    EnvironmentSettings settings = ENVIRONMENT_SETTINGS_DEFAULT,
) {
    return {
        .kind = EnvironmentSourceKind.SOLID,
        .solid_color = color,
        .settings = settings,
    };
}
