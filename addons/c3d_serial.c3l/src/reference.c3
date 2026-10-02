module c3d::serial;

import c3d;
import c3d::asset;

<*
 Encode a keyed geometry reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_geometry(&self, Writer* writer, GeometryId id) {
    if (!id.index && !id.generation) {
        writer.write_uint(INDEX_NONE);
        return;
    }
    String key = self.assets.geometries.try_get(id)!.header.key;
    write_key(self, writer, key)!;
}

<*
 Resolve a keyed geometry reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn GeometryId? ReadContext.read_geometry(&self, Reader* reader) {
    uint index = reader.read_uint()!;
    if (index == INDEX_NONE) return (GeometryId){};
    if (index >= self.keys.len) return c3d::ASSET_FORMAT_ERROR~;
    return self.assets.find_geometry(self.keys[index]) ?? c3d::INVALID_ID~;
}

<*
 Encode a keyed material reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_material(&self, Writer* writer, MaterialId id) {
    if (!id.index && !id.generation) {
        writer.write_uint(INDEX_NONE);
        return;
    }
    String key = self.assets.materials.try_get(id)!.header.key;
    write_key(self, writer, key)!;
}

<*
 Resolve a keyed material reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn MaterialId? ReadContext.read_material(&self, Reader* reader) {
    uint index = reader.read_uint()!;
    if (index == INDEX_NONE) return (MaterialId){};
    if (index >= self.keys.len) return c3d::ASSET_FORMAT_ERROR~;
    return self.assets.find_material(self.keys[index]) ?? c3d::INVALID_ID~;
}

<*
 Encode a keyed texture reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_texture(&self, Writer* writer, TextureId id) {
    if (!id.index && !id.generation) {
        writer.write_uint(INDEX_NONE);
        return;
    }
    String key = self.assets.textures.try_get(id)!.header.key;
    write_key(self, writer, key)!;
}

<*
 Resolve a keyed texture reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn TextureId? ReadContext.read_texture(&self, Reader* reader) {
    uint index = reader.read_uint()!;
    if (index == INDEX_NONE) return (TextureId){};
    if (index >= self.keys.len) return c3d::ASSET_FORMAT_ERROR~;
    return self.assets.find_texture(self.keys[index]) ?? c3d::INVALID_ID~;
}

<*
 Encode a keyed sampler reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_sampler(&self, Writer* writer, SamplerId id) {
    if (!id.index && !id.generation) {
        writer.write_uint(INDEX_NONE);
        return;
    }
    String key = self.assets.samplers.try_get(id)!.header.key;
    write_key(self, writer, key)!;
}

<*
 Resolve a keyed sampler reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn SamplerId? ReadContext.read_sampler(&self, Reader* reader) {
    uint index = reader.read_uint()!;
    if (index == INDEX_NONE) return (SamplerId){};
    if (index >= self.keys.len) return c3d::ASSET_FORMAT_ERROR~;
    return self.assets.find_sampler(self.keys[index]) ?? c3d::INVALID_ID~;
}

<*
 Encode a keyed model reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_model(&self, Writer* writer, ModelId id) {
    if (!id.index && !id.generation) {
        writer.write_uint(INDEX_NONE);
        return;
    }
    String key = self.assets.models.try_get(id)!.header.key;
    write_key(self, writer, key)!;
}

<*
 Resolve a keyed model reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn ModelId? ReadContext.read_model(&self, Reader* reader) {
    uint index = reader.read_uint()!;
    if (index == INDEX_NONE) return (ModelId){};
    if (index >= self.keys.len) return c3d::ASSET_FORMAT_ERROR~;
    return self.assets.find_model(self.keys[index]) ?? c3d::INVALID_ID~;
}

<*
 Encode a keyed clip reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_clip(&self, Writer* writer, ClipId id) {
    if (!id.index && !id.generation) {
        writer.write_uint(INDEX_NONE);
        return;
    }
    String key = self.assets.clips.try_get(id)!.header.key;
    write_key(self, writer, key)!;
}

<*
 Resolve a keyed clip reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn ClipId? ReadContext.read_clip(&self, Reader* reader) {
    uint index = reader.read_uint()!;
    if (index == INDEX_NONE) return (ClipId){};
    if (index >= self.keys.len) return c3d::ASSET_FORMAT_ERROR~;
    return self.assets.find_clip(self.keys[index]) ?? c3d::INVALID_ID~;
}

<*
 Encode a keyed skeleton reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_skeleton(&self, Writer* writer, SkeletonId id) {
    if (!id.index && !id.generation) {
        writer.write_uint(INDEX_NONE);
        return;
    }
    String key = self.assets.skeletons.try_get(id)!.header.key;
    write_key(self, writer, key)!;
}

<*
 Resolve a keyed skeleton reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn SkeletonId? ReadContext.read_skeleton(&self, Reader* reader) {
    uint index = reader.read_uint()!;
    if (index == INDEX_NONE) return (SkeletonId){};
    if (index >= self.keys.len) return c3d::ASSET_FORMAT_ERROR~;
    return self.assets.find_skeleton(self.keys[index]) ?? c3d::INVALID_ID~;
}

<*
 Encode a keyed environment reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_environment(&self, Writer* writer, EnvironmentId id) {
    if (!id.index && !id.generation) {
        writer.write_uint(INDEX_NONE);
        return;
    }
    String key = self.assets.environments.try_get(id)!.header.key;
    write_key(self, writer, key)!;
}

<*
 Resolve a keyed environment reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn EnvironmentId? ReadContext.read_environment(&self, Reader* reader) {
    uint index = reader.read_uint()!;
    if (index == INDEX_NONE) return (EnvironmentId){};
    if (index >= self.keys.len) return c3d::ASSET_FORMAT_ERROR~;
    return self.assets.find_environment(self.keys[index]) ?? c3d::INVALID_ID~;
}

<*
 Encode a keyed shader reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_shader(&self, Writer* writer, ShaderId id) {
    if (!id.index && !id.generation) {
        writer.write_uint(INDEX_NONE);
        return;
    }
    String key = self.assets.shaders.try_get(id)!.header.key;
    write_key(self, writer, key)!;
}

<*
 Resolve a keyed shader reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn ShaderId? ReadContext.read_shader(&self, Reader* reader) {
    uint index = reader.read_uint()!;
    if (index == INDEX_NONE) return (ShaderId){};
    if (index >= self.keys.len) return c3d::ASSET_FORMAT_ERROR~;
    return self.assets.find_shader(self.keys[index]) ?? c3d::INVALID_ID~;
}

<*
 Encode a keyed compute shader reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_compute_shader(&self, Writer* writer, ComputeShaderId id) {
    if (!id.index && !id.generation) {
        writer.write_uint(INDEX_NONE);
        return;
    }
    String key = self.assets.compute_shaders.try_get(id)!.header.key;
    write_key(self, writer, key)!;
}

<*
 Resolve a keyed compute shader reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn ComputeShaderId? ReadContext.read_compute_shader(&self, Reader* reader) {
    uint index = reader.read_uint()!;
    if (index == INDEX_NONE) return (ComputeShaderId){};
    if (index >= self.keys.len) return c3d::ASSET_FORMAT_ERROR~;
    return self.assets.find_compute_shader(self.keys[index]) ?? c3d::INVALID_ID~;
}
