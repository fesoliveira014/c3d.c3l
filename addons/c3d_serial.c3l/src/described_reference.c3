module c3d::serial;

import c3d;
import c3d::asset;

fn void? write_described_asset(
    WriteContext* context,
    Writer* writer,
    AssetKind kind,
    void* value,
) @private {
    switch (kind) {
        case GEOMETRY: context.write_geometry(writer, *(GeometryId*)value)!;
        case TEXTURE: context.write_texture(writer, *(TextureId*)value)!;
        case SAMPLER: context.write_sampler(writer, *(SamplerId*)value)!;
        case MATERIAL: context.write_material(writer, *(MaterialId*)value)!;
        case MODEL: context.write_model(writer, *(ModelId*)value)!;
        case CLIP: context.write_clip(writer, *(ClipId*)value)!;
        case SKELETON: context.write_skeleton(writer, *(SkeletonId*)value)!;
        case SHADER: context.write_shader(writer, *(ShaderId*)value)!;
        case COMPUTE_SHADER: context.write_compute_shader(writer, *(ComputeShaderId*)value)!;
        case ENVIRONMENT: context.write_environment(writer, *(EnvironmentId*)value)!;
        case FONT:
            FontId id = *(FontId*)value;
            if (!id.index && !id.generation) {
                writer.write_uint(INDEX_NONE);
                return;
            }
            write_key(context, writer, context.assets.fonts.try_get(id)!.header.key)!;
        case CUSTOM: return c3d::UNSUPPORTED~;
    }
}

fn void? read_described_asset(
    ReadContext* context,
    Reader* reader,
    AssetKind kind,
    void* value,
) @private {
    switch (kind) {
        case GEOMETRY: *(GeometryId*)value = context.read_geometry(reader)!;
        case TEXTURE: *(TextureId*)value = context.read_texture(reader)!;
        case SAMPLER: *(SamplerId*)value = context.read_sampler(reader)!;
        case MATERIAL: *(MaterialId*)value = context.read_material(reader)!;
        case MODEL: *(ModelId*)value = context.read_model(reader)!;
        case CLIP: *(ClipId*)value = context.read_clip(reader)!;
        case SKELETON: *(SkeletonId*)value = context.read_skeleton(reader)!;
        case SHADER: *(ShaderId*)value = context.read_shader(reader)!;
        case COMPUTE_SHADER: *(ComputeShaderId*)value = context.read_compute_shader(reader)!;
        case ENVIRONMENT: *(EnvironmentId*)value = context.read_environment(reader)!;
        case FONT:
            uint index = reader.read_uint()!;
            if (index == INDEX_NONE) {
                *(FontId*)value = {};
                return;
            }
            if (index >= context.keys.len) return c3d::ASSET_FORMAT_ERROR~;
            *(FontId*)value = context.assets.find_font(context.keys[index]) ?? c3d::INVALID_ID~!;
        case CUSTOM: return c3d::UNSUPPORTED~;
    }
}
