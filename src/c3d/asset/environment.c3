module c3d::asset;

import c3d;
import c3d::light;
import c3d::material;
import c3d::pool;
import std::math;

<* Pool of environment records addressed by EnvironmentId. *>
alias EnvironmentPool = Pool{EnvironmentAsset, EnvironmentId};

const uint MIN_ENVIRONMENT_SPECULAR_SIZE @local = 32; // Six roughness mips need 32 texels at mip zero.

<* Environment record borrowing its source texture. *>
struct EnvironmentAsset {
    AssetHeader header;
    EnvironmentDesc desc;
}

<*
 Validate environment authoring data against current source metadata.
 @param [&in] self : "Store resolving texture identities and descriptions."
 @return? c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::UNSUPPORTED
*>
fn void? AssetStore.validate_environment(&self, EnvironmentDesc desc) {
    if (desc.settings.specular_size < MIN_ENVIRONMENT_SPECULAR_SIZE) {
        return c3d::INVALID_ARGUMENT~;
    }

    switch (desc.kind) {
        case SOLID:
            if (!math::is_finite(desc.solid_color.x)
                || !math::is_finite(desc.solid_color.y)
                || !math::is_finite(desc.solid_color.z)
                || desc.solid_color.x < 0
                || desc.solid_color.y < 0
                || desc.solid_color.z < 0) {
                return c3d::INVALID_ARGUMENT~;
            }
        case TEXTURE:
            TextureAsset* source = self.textures.try_get(desc.source)!;
            TextureDesc source_desc = source.desc;
            if (!source_desc.width || !source_desc.height) return c3d::INVALID_ARGUMENT~;
            if (source_desc.depth) return c3d::UNSUPPORTED~;

            if (source_desc.is_cube) {
                if (source_desc.width != source_desc.height
                    || source_desc.layers != material::CUBE_FACE_COUNT) {
                    return c3d::INVALID_ARGUMENT~;
                }
                switch (source_desc.format) {
                    case RGBA8_UNORM:
                    case RGBA8_SRGB:
                    case RGBA16_FLOAT:
                    case RGBA32_FLOAT:
                        return;
                    case BC1_RGBA_UNORM:
                    case BC1_RGBA_SRGB:
                    case BC3_UNORM:
                    case BC3_SRGB:
                    case BC4_UNORM:
                    case BC5_UNORM:
                    case BC6H_UFLOAT:
                    case BC7_UNORM:
                    case BC7_SRGB:
                        return c3d::UNSUPPORTED~;
                }
            }

            if (source_desc.layers != 1) return c3d::UNSUPPORTED~;
            if (source_desc.format != RGBA16_FLOAT && source_desc.format != RGBA32_FLOAT) {
                return c3d::UNSUPPORTED~;
            }
            if (!desc.settings.conversion_size) return c3d::INVALID_ARGUMENT~;
    }
    return;
}

<*
 Add an environment without taking ownership of its source.
 @param [&inout] self : "Owns the new record and copied key."
 @return? c3d::INVALID_ARGUMENT, c3d::INVALID_ID, c3d::UNSUPPORTED, c3d::CAPACITY_EXCEEDED
*>
fn EnvironmentId? AssetStore.add_environment(&self, EnvironmentDesc desc, String key = "") {
    check_key(self, key)!;
    self.validate_environment(desc)!;
    EnvironmentId id = self.environments.add({})!;
    *self.environments.get(id) = {
        .header = { .key = copy_string(self.allocator, key), .revision = 1 },
        .desc = desc,
    };
    register_key(self, key, typed_ref(AssetKind.ENVIRONMENT, id));
    return id;
}

<*
 Borrow the environment record for a live id.
 @param [&inout] self : "Store owning the borrowed record."
 @require self.environments.is_live(environment)
*>
fn EnvironmentAsset* AssetStore.environment(&self, EnvironmentId environment) {
    return self.environments.get(environment);
}

<*
 Advance the content revision after editing an environment.
 @param [&inout] self : "Store whose environment revision advances."
 @require self.environments.is_live(environment)
*>
fn void AssetStore.mark_environment_dirty(&self, EnvironmentId environment) {
    self.environments.get(environment).header.revision++;
}

<*
 Remove an environment while retaining its source texture.
 @param [&inout] self : "Store whose environment record is removed."
 @require self.environments.is_live(environment)
*>
fn void AssetStore.remove_environment(&self, EnvironmentId environment) {
    EnvironmentAsset* record = self.environments.get(environment);
    forget_key(self, record.header.key);
    free_string(self.allocator, record.header.key);
    *record = {};
    self.environments.remove(environment);
}

<*
 Find an environment by its asset key.
 @param [&in] self : "Store resolving the shared key namespace."
 @return? NOT_FOUND, c3d::INVALID_ARGUMENT
*>
fn EnvironmentId? AssetStore.find_environment(&self, String key) {
    AssetRef found = self.find(key)!;
    if (found.kind != AssetKind.ENVIRONMENT) return c3d::INVALID_ARGUMENT~;
    return (EnvironmentId){ .index = found.id.index, .generation = found.id.generation };
}
