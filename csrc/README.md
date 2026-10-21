# Native image decoder

`stb_image.h` is the unmodified stb_image v2.30 header from
[nothings/stb revision 013ac3beddff3dbffafd5177e7972067cd2b5083](https://github.com/nothings/stb/blob/013ac3beddff3dbffafd5177e7972067cd2b5083/stb_image.h).
Its SHA-256 is `594c2fe35d49488b4382dbfaec8f98366defca819d916ac95becf3e75f4200b3`.
The full upstream dual-license notice remains in the header; c3d uses its MIT option.

`stb_image.c` enables only PNG, JPEG and Radiance HDR decoding from memory.
The C3 package manifest compiles this translation unit using c3c's selected C
compiler. A working C compiler is required.

The private declarations in `c3d::asset::image` are the only C3 entry points.
Decoded native memory is copied into the requested C3 allocator and freed with
`stbi_image_free`. File reads use a separately freed heap allocation so the
caller's temporary allocator retains its normal lifetime.

# Native font parser

`stb_truetype.h` is the unmodified stb_truetype v1.26 header from
[nothings/stb revision 013ac3beddff3dbffafd5177e7972067cd2b5083](https://github.com/nothings/stb/blob/013ac3beddff3dbffafd5177e7972067cd2b5083/stb_truetype.h),
the stb_image revision. Its SHA-256 is `a34d8d536ce7c11b9163ab2d524721c1f4df1452cce6595c4f11d3048384f925`.
The full upstream dual-license notice remains in the header; c3d uses its MIT option.

`stb_truetype.c` compiles the implementation with C linkage. Dear ImGui carries its own copy with internal
linkage in both prebuilt libraries, so the `stbtt_` symbols do not clash. The private declarations in
`c3d::asset::truetype` are the only C3 entry points; they mirror `stbtt_fontinfo` (160 bytes) and `stbtt_vertex`
(14 bytes) with layout pins. Shapes and bitmaps are allocated and freed by stb_truetype's default `malloc`.
`c3d::asset` validates the sfnt table directory before stb_truetype reads a file, because stb_truetype does not
bounds-check.

Test inputs for both decoders are described in `test/fixtures/README.md` and `test/fixtures/fonts/README.md`; release
packages do not include them.
