module c3d::asset::image;

import c3d;
import std::collections::list;
import std::compression::deflate;
import std::hash::adler32;
import std::hash::crc32;
import std::io::file;

const char[8] PNG_SIGNATURE @local = { 0x89, 'P', 'N', 'G', 0x0D, 0x0A, 0x1A, 0x0A };
const char PNG_BIT_DEPTH @local = 8;
const char PNG_COLOR_TYPE_RGBA @local = 6;
const char PNG_FILTER_NONE @local = 0;
const char[2] ZLIB_HEADER @local = { 0x78, 0x01 }; // deflate, 32 KiB window; zlib needs 0x7801 % 31 == 0
const usz PNG_BYTES_PER_PIXEL @local = 4;

<*
 Encode tightly packed RGBA8 rows as a PNG file.
 @param pixels : "Width x height x 4 bytes, top row first."
 @return? c3d::INVALID_ARGUMENT, c3d::ASSET_IO_ERROR
*>
fn void? write_png(String path, uint width, uint height, char[] pixels) {
    usz row_bytes = (usz)width * PNG_BYTES_PER_PIXEL;
    if (width == 0 || height == 0 || row_bytes > int::max || pixels.len != row_bytes * height) {
        return c3d::INVALID_ARGUMENT~;
    }

    @pool() {
        char[] filtered = alloc::new_array(tmem, char, (sz)((row_bytes + 1) * height));
        for (usz row = 0; row < height; row++) {
            usz start = row * (row_bytes + 1);
            filtered[start] = PNG_FILTER_NONE;
            filtered[start + 1:row_bytes] = pixels[row * row_bytes:row_bytes];
        }
        char[]? compressed = deflate::compress(tmem, filtered);
        if (catch compressed) return c3d::ASSET_IO_ERROR~;

        List{char} header;
        header.tinit();
        append_big_endian(&header, width);
        append_big_endian(&header, height);
        header.push_all({ PNG_BIT_DEPTH, PNG_COLOR_TYPE_RGBA, 0, 0, 0 });

        List{char} image_data;
        image_data.tinit((sz)compressed.len + ZLIB_HEADER.len + uint::size);
        image_data.push_all(ZLIB_HEADER[..]);
        image_data.push_all(compressed);
        append_big_endian(&image_data, adler32::hash(filtered));

        List{char} file_bytes;
        file_bytes.tinit((sz)image_data.len() + 64);
        file_bytes.push_all(PNG_SIGNATURE[..]);
        append_chunk(&file_bytes, "IHDR", header.array_view());
        append_chunk(&file_bytes, "IDAT", image_data.array_view());
        append_chunk(&file_bytes, "IEND", {});
        if (catch file::save(path, file_bytes.array_view())) return c3d::ASSET_IO_ERROR~;
    };
}

fn void append_big_endian(List{char}* bytes, uint value) @local {
    bytes.push((char)(value >> 24));
    bytes.push((char)(value >> 16));
    bytes.push((char)(value >> 8));
    bytes.push((char)value);
}

fn void append_chunk(List{char}* bytes, String chunk_type, char[] data) @local {
    append_big_endian(bytes, (uint)data.len);
    bytes.push_all(chunk_type);
    bytes.push_all(data);
    Crc32 checksum;
    checksum.init();
    checksum.update(chunk_type);
    checksum.update(data);
    append_big_endian(bytes, checksum.final());
}
