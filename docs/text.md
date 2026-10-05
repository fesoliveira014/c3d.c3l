# Text

Module `c3d::asset` loads TrueType, OpenType (CFF) and collection fonts, measures and places one line of UTF-8 text,
and builds glyph outlines on first use. Module `c3d::render` draws placed glyphs as glyph runs in an overlay list
([Overlay list](overlay.md)). Glyphs render from their outlines on the GPU with the Slug method: no atlas, no distance
field, sharp at every size.

## Fonts in the store

```c3
FontId font = assets.add_font(file_bytes, asset::default_font_desc(), "ui/regular")!;
```

- `add_font` copies the bytes; `add_font_owned` takes bytes allocated with the store allocator on success.
- `FontDesc.face_index` selects a face of a collection; zero for a single-face file.
- `max_glyphs`, `curve_texels` and `band_texels` are fixed capacities, allocated once. Texel counts round up to rows
  of 4,096 texels and stop at 4,096 rows. The defaults hold the whole committed CJK subset (4,184 glyphs) with room
  to spare; a Latin UI font fits in far less. See [Capacities and costs](#capacities-and-costs).
- `remove_font` frees the file and outlines. The renderer retires the font's textures on its next frame.

Faults of `add_font` and `add_font_owned`:

| Fault | Meaning |
| --- | --- |
| `INVALID_ARGUMENT` | Key taken; a zero capacity or one above 4,096 rows; `face_index` past the file's faces |
| `ASSET_FORMAT_ERROR` | Not an sfnt or collection; a table outside the file; a missing or short required table; an unreadable face |
| `UNSUPPORTED` | No `glyf` with `loca` and no `CFF ` table: CFF2 and bitmap-only fonts |
| `CAPACITY_EXCEEDED` | The store's font pool is full |

Font files are trusted past their table directory. `add_font` checks the directory and the range of every table
before stb_truetype reads them, but stb_truetype does not bounds-check the tables' contents. Load fonts the
application ships or vets.

## Measuring and placing a line

```c3
TextExtent extent = assets.measure_text(font, "Hello", 24)!;
GlyphPlacement[64] placements;
usz count = assets.place_text(font, "Hello", placements[..])!;
```

- The pen starts at 0. Each code point maps through the font's cmap (glyph 0, `.notdef`, when missing), the pen
  moves by the pair kerning of the previous glyph and this one, the glyph is placed, and the pen moves by its
  advance. Control characters are not interpreted.
- `measure_text` returns the width and the font's ascent and descent in pixels at `size_pixels`. It builds nothing.
- `place_text` writes one `GlyphPlacement` per glyph with an outline, in em units from the line origin (`y` is 0 on
  one line). Spaces and other empty glyphs keep their advance and produce no placement.
- `place_text` builds outlines for glyphs it meets for the first time and advances the font revision once when it
  does. Outline storage is append-only: built glyphs never change while the font lives.
- `font_metrics` gives ascent, descent (negative) and line gap in em units, from `hhea`.

Faults of `place_text`: `INVALID_ARGUMENT` for invalid UTF-8 and `CAPACITY_EXCEEDED` for a `placements` slice shorter
than the glyphs with outlines; both fault before anything is built. `CAPACITY_EXCEEDED` also reports a full glyph
table, curve storage or band storage, or one glyph whose band data exceeds a row. Glyphs built before that fault
stay valid. `measure_text` faults `INVALID_ARGUMENT` for invalid UTF-8.

Kerning comes from GPOS pair adjustments (formats 1 and 2, advance only) or, without GPOS, the `kern` table.
stb_truetype reads no other GPOS lookups, no extension lookups and no GSUB: there is no shaping, so ligatures,
contextual forms, complex scripts, bidirectional text and vertical layout are out of scope.

## Fallback across fonts

A glyph run uses one font. To mix fonts in a line, split it where the primary font has no glyph:

```c3
bool primary = @ok(assets.find_glyph(latin, code_point)); // find_glyph faults NOT_FOUND for an unmapped code point
```

Place each segment with its own font and start the next segment at the previous one's `measure_text` width. Kerning
does not apply across segments.

## Drawing

```c3
list.add_glyphs({
    .font        = font,
    .glyphs      = placements[:count],
    .origin      = { math::round(x), math::round(baseline_y) },
    .size_pixels = 24,
    .color       = { 1, 1, 1, 1 },
})!;
```

- `origin` is the baseline start in output pixels; `color` is sRGB with straight alpha.
- Core draws at `origin` exactly. Round `origin.y` to whole pixels for a crisp baseline; leave it fractional for
  smooth motion.
- Glyph runs and rectangles share the list's clips, ordering and draws: see [Overlay list](overlay.md).
- `prepare_overlay_list` uploads the rows a font gained since its last upload. Its `INVALID_ID` covers a dead font
  and its `INVALID_ARGUMENT` a glyph that is past the font or has no built outline.

## Bitmap rasterization

`glyph_bitmap_box` and `rasterize_glyph` rasterize one glyph with stb_truetype into one byte of coverage per pixel at
a size and subpixel pen offset. The `text` example's `--compare` mode uses them as the reference for small text.

## Capacities and costs

Measured with `text --stats` (CPU; any machine):

| Font | Glyphs | Curve texels per glyph | Band texels per glyph | Store bytes per glyph | GPU bytes per glyph |
| --- | --- | --- | --- | --- | --- |
| Noto Sans, U+0020 to U+017F, Greek and Cyrillic | 695 | 25.8 | 113.3 | 865 | 659 |
| Noto Sans CJK SC subset, every glyph | 4,181 | 67.9 | 271.9 | 2,174 | 1,631 |

The store holds curve texels as f32 (16 bytes) and band texels as two u16 values (4 bytes); the GPU holds curves as
f16 (8 bytes) and bands as `R32_UINT` (4 bytes). The CJK subset fills 70 curve rows and 278 band rows. Defaults:
5,120 glyphs, 96 curve rows (6 MiB stored, 3 MiB on the GPU) and 384 band rows (6 MiB each), about 1.37 times the
subset. A font whose glyphs need more faults `CAPACITY_EXCEEDED` from `place_text`; give it a larger `FontDesc`.

Building outlines for a first-seen paragraph of 100 distinct hanzi takes 3.3 ms in `place_text` at `--opt O3`
(27 ms unoptimized), measured with `text --stats` on an Intel i9-14900K under WSL. Placing text whose glyphs exist
already decodes, looks up and kerns only.

GPU time and preparation cost of glyph runs: recorded after the RTX 4090 runs of `text --benchmark`.

## Credits

The glyph shader ports the reference pixel shader of Eric Lengyel's Slug algorithm
([github.com/EricLengyel/Slug](https://github.com/EricLengyel/Slug)), MIT licensed (`LICENSE-slug.txt`); the Slug
patent is dedicated to the public domain. Fonts are parsed and rasterized with stb_truetype v1.26 by Sean Barrett
(`csrc/README.md`).
