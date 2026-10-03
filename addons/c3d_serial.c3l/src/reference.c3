module c3d::serial;

import c3d;
import c3d::asset;

<*
 Encode a keyed geometry reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_geometry(&self, Writer* writer, GeometryId id) {
    return write_asset_key(
        context: self,
        writer: writer,
        id: id,
        pool: &self.assets.geometries,
    );
}

<*
 Resolve a keyed geometry reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn GeometryId? ReadContext.read_geometry(&self, Reader* reader) {
    return read_asset_key(
        context: self,
        reader: reader,
        $Type: GeometryId,
        find: &AssetStore.find_geometry,
    );
}

<*
 Encode a keyed material reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_material(&self, Writer* writer, MaterialId id) {
    return write_asset_key(
        context: self,
        writer: writer,
        id: id,
        pool: &self.assets.materials,
    );
}

<*
 Resolve a keyed material reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn MaterialId? ReadContext.read_material(&self, Reader* reader) {
    return read_asset_key(
        context: self,
        reader: reader,
        $Type: MaterialId,
        find: &AssetStore.find_material,
    );
}

<*
 Encode a keyed texture reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_texture(&self, Writer* writer, TextureId id) {
    return write_asset_key(
        context: self,
        writer: writer,
        id: id,
        pool: &self.assets.textures,
    );
}

<*
 Resolve a keyed texture reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn TextureId? ReadContext.read_texture(&self, Reader* reader) {
    return read_asset_key(
        context: self,
        reader: reader,
        $Type: TextureId,
        find: &AssetStore.find_texture,
    );
}

<*
 Encode a keyed sampler reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_sampler(&self, Writer* writer, SamplerId id) {
    return write_asset_key(
        context: self,
        writer: writer,
        id: id,
        pool: &self.assets.samplers,
    );
}

<*
 Resolve a keyed sampler reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn SamplerId? ReadContext.read_sampler(&self, Reader* reader) {
    return read_asset_key(
        context: self,
        reader: reader,
        $Type: SamplerId,
        find: &AssetStore.find_sampler,
    );
}

<*
 Encode a keyed model reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_model(&self, Writer* writer, ModelId id) {
    return write_asset_key(
        context: self,
        writer: writer,
        id: id,
        pool: &self.assets.models,
    );
}

<*
 Resolve a keyed model reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn ModelId? ReadContext.read_model(&self, Reader* reader) {
    return read_asset_key(
        context: self,
        reader: reader,
        $Type: ModelId,
        find: &AssetStore.find_model,
    );
}

<*
 Encode a keyed clip reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_clip(&self, Writer* writer, ClipId id) {
    return write_asset_key(
        context: self,
        writer: writer,
        id: id,
        pool: &self.assets.clips,
    );
}

<*
 Resolve a keyed clip reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn ClipId? ReadContext.read_clip(&self, Reader* reader) {
    return read_asset_key(
        context: self,
        reader: reader,
        $Type: ClipId,
        find: &AssetStore.find_clip,
    );
}

<*
 Encode a keyed skeleton reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_skeleton(&self, Writer* writer, SkeletonId id) {
    return write_asset_key(
        context: self,
        writer: writer,
        id: id,
        pool: &self.assets.skeletons,
    );
}

<*
 Resolve a keyed skeleton reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn SkeletonId? ReadContext.read_skeleton(&self, Reader* reader) {
    return read_asset_key(
        context: self,
        reader: reader,
        $Type: SkeletonId,
        find: &AssetStore.find_skeleton,
    );
}

<*
 Encode a keyed environment reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_environment(&self, Writer* writer, EnvironmentId id) {
    return write_asset_key(
        context: self,
        writer: writer,
        id: id,
        pool: &self.assets.environments,
    );
}

<*
 Resolve a keyed environment reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn EnvironmentId? ReadContext.read_environment(&self, Reader* reader) {
    return read_asset_key(
        context: self,
        reader: reader,
        $Type: EnvironmentId,
        find: &AssetStore.find_environment,
    );
}

<*
 Encode a keyed shader reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_shader(&self, Writer* writer, ShaderId id) {
    return write_asset_key(
        context: self,
        writer: writer,
        id: id,
        pool: &self.assets.shaders,
    );
}

<*
 Resolve a keyed shader reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn ShaderId? ReadContext.read_shader(&self, Reader* reader) {
    return read_asset_key(
        context: self,
        reader: reader,
        $Type: ShaderId,
        find: &AssetStore.find_shader,
    );
}

<*
 Encode a keyed compute shader reference.
 @param [&inout] writer : "Receives the portable key index."
 @return? c3d::INVALID_ID, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn void? WriteContext.write_compute_shader(&self, Writer* writer, ComputeShaderId id) {
    return write_asset_key(
        context: self,
        writer: writer,
        id: id,
        pool: &self.assets.compute_shaders,
    );
}

<*
 Resolve a keyed compute shader reference.
 @param [&inout] reader : "Contains the next portable key reference."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::INVALID_ID
*>
fn ComputeShaderId? ReadContext.read_compute_shader(&self, Reader* reader) {
    return read_asset_key(
        context: self,
        reader: reader,
        $Type: ComputeShaderId,
        find: &AssetStore.find_compute_shader,
    );
}

macro void? write_asset_key(
    WriteContext* context,
    Writer* writer,
    id,
    pool,
) @local {
    if (!id.index && !id.generation) {
        writer.write_uint(INDEX_NONE);
        return;
    }
    String key = pool.try_get(id)!.header.key;
    write_key(context, writer, key)!;
}

macro read_asset_key(
    ReadContext* context,
    Reader* reader,
    $Type,
    find,
) @local {
    uint index = reader.read_uint()!;
    if (index == INDEX_NONE) return ($Type){};
    if (index >= context.keys.len) return c3d::ASSET_FORMAT_ERROR~;
    return find(context.assets, context.keys[index]) ?? c3d::INVALID_ID~;
}
