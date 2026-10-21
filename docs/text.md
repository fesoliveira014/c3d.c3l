# Text

Module `c3d::asset` loads TrueType, OpenType (CFF) and collection fonts, measures and places one line of UTF-8 text, and
builds glyph outlines on first use. Module `c3d::render` draws placed glyphs as glyph runs in an overlay list
([Overlay list](overlay.md)). Glyphs render from their outlines on the GPU with the Slug method: no atlas, no distance field,
sharp at every size.

## Quick start

```c3
import c3d::asset;
import c3d::render;

FontId font = assets.add_font(file_bytes, asset::default_font_desc(), "ui/regular")!;

GlyphPlacement[64] placements;
usz count = assets.place_text(font, "Hello", placements[..])!;

list.add_glyphs({
    .font        = font,
    .glyphs      = placements[:count],
    .origin      = { math::round(x), math::round(baseline_y) },
    .size_pixels = 24,
    .color       = { 1, 1, 1, 1 },
})!;
```

`list` is an `OverlayList`; the renderer prepares and draws it as described in [Overlay list](overlay.md).

## Concepts

- The asset store owns the font file and the glyph outlines. The renderer mirrors them and uploads new outline rows on the
  next prepare.
- Outlines are built the first time `place_text` meets a glyph. Outline storage is append-only: built glyphs never change
  while the font lives. Building advances the font revision once per call.
- Placements are in em units from the line origin. `size_pixels` scales them when the run is drawn.
- A glyph run uses one font, one size and one color.
- Capacities (`max_glyphs`, `curve_texels`, `band_texels`) are fixed when the font is added.

## Fonts in the store

- `add_font` copies the bytes; `add_font_owned` takes bytes allocated with the store allocator on success and leaves them
  with the caller on a fault.
- `find_font(key)` returns the id of a key and faults `NOT_FOUND` for an unknown key and `INVALID_ARGUMENT` for a key of another
  asset kind.
- `remove_font` frees the file and outlines. The renderer retires the font's textures on its next frame.
- `replace_font` and `replace_font_owned` swap the file and capacities under the same id and key. Built glyphs are discarded
  and rebuild on next placement. The renderer re-uploads the outline rows from the start, and recreates its textures when
  the capacities changed. A UI clears its cached placements when a font of its font sets is replaced. Glyph indices from the
  old face are not valid for the new one: place text again.

`FontDesc`:

| Field | Meaning | Default (`default_font_desc()`) |
| --- | --- | --- |
| `face_index` | Face within a collection; zero for a single-face file. | 0 |
| `max_glyphs` | Glyph outlines the font keeps. | 5,120 |
| `curve_texels` | Curve storage, rounded up to rows of 4,096 texels, at most 4,096 rows. | 96 rows |
| `band_texels` | Band storage, same rounding and limit. | 384 rows |

The defaults hold the whole committed CJK subset, 4,197 glyphs, with room to spare; a Latin UI font fits in far less. Storage
is allocated once, at these costs:

| Capacity | In the store | On the GPU |
| --- | --- | --- |
| One curve row (4,096 texels) | 64 KiB | 32 KiB |
| One band row (4,096 texels) | 16 KiB | 16 KiB |
| One `max_glyphs` entry | 32 bytes | none |

The store also keeps 4 bytes per glyph of the font file. The defaults take 6 MiB of curves and 6 MiB of bands in the store, and
3 MiB and 6 MiB on the GPU. A font whose glyphs need more faults `CAPACITY_EXCEEDED` from `place_text`; give it a larger
`FontDesc`.

Faults of `add_font` and `add_font_owned`; the replace calls fault the same way, without `CAPACITY_EXCEEDED`:

| Fault | Meaning |
| --- | --- |
| `INVALID_ARGUMENT` | Key taken; a zero capacity or one above 4,096 rows; `face_index` past the file's faces |
| `ASSET_FORMAT_ERROR` | Not an sfnt or collection; a table outside the file; a missing or short required table; an unreadable face |
| `UNSUPPORTED` | No `glyf` with `loca` and no `CFF ` table: CFF2 and bitmap-only fonts |
| `CAPACITY_EXCEEDED` | The store's font pool is full |

Font files are trusted past their table directory. `add_font` checks the directory and the range of every table before
stb_truetype reads them, but stb_truetype does not bounds-check the tables' contents. Load fonts the application ships or
vets.

## Measure and place a line

```c3
TextExtent extent = assets.measure_text(font, "Hello", 24)!;
GlyphPlacement[64] placements;
usz count = assets.place_text(font, "Hello", placements[..])!;
```

- The pen starts at 0. Each code point maps through the font's cmap (glyph 0, `.notdef`, when missing), the pen moves by the
  pair kerning of the previous glyph and this one, the glyph is placed, and the pen moves by its advance. Control characters
  are not interpreted.
- `measure_text` returns the width and the font's ascent and descent in pixels at `size_pixels`. It builds nothing.
- `place_text` writes one `GlyphPlacement` per glyph with an outline, in em units from the line origin (`y` is 0 on one
  line), and returns the count. Spaces and other empty glyphs keep their advance and produce no placement.
- `font_metrics` gives ascent, descent (negative) and line gap in em units, from `hhea`.

Faults of `place_text`: `INVALID_ARGUMENT` for invalid UTF-8 and `CAPACITY_EXCEEDED` for a `placements` slice shorter than
the glyphs with outlines; both fault before anything is built. `CAPACITY_EXCEEDED` also reports a full glyph table, curve
storage or band storage, or one glyph whose band data exceeds a row. Glyphs built before that fault stay valid.
`measure_text` faults `INVALID_ARGUMENT` for invalid UTF-8.

Kerning comes from GPOS pair adjustments (formats 1 and 2, advance only) or, without GPOS, the `kern` table. stb_truetype
reads no other GPOS lookups, no extension lookups and no GSUB.

## Fall back across fonts

A glyph run uses one font. To mix fonts in a line, split it where the primary font has no glyph:

```c3
bool primary = @ok(assets.find_glyph(latin, code_point)); // find_glyph faults NOT_FOUND for an unmapped code point
```

Place each segment with its own font and start the next segment at the previous one's `measure_text` width. Kerning does not
apply across segments.

## Draw a run

- `origin` is the baseline start in output pixels; `color` is sRGB with straight alpha.
- Core draws at `origin` exactly. Round `origin.y` to whole pixels for a crisp baseline; leave it fractional for smooth
  motion.
- Glyph runs and rectangles share the list's clips, ordering and draws: see [Overlay list](overlay.md).
- `prepare_overlay_list` uploads the rows a font gained since its last upload. Its `INVALID_ID` covers a dead font and its
  `INVALID_ARGUMENT` a glyph that is past the font or has no built outline.

## Rasterize a bitmap

`glyph_bitmap_box` and `rasterize_glyph` rasterize one glyph with stb_truetype into one byte of coverage per pixel at a size
and subpixel pen offset. The `text` example's `--compare` mode uses them as the reference for small text.

## Limits

- There is no shaping: no ligatures, contextual forms, complex scripts, bidirectional text or vertical layout.
- Text is one line per call; the application breaks lines.
- Placing text whose glyphs already have outlines decodes, looks up and kerns only. A UI that re-places unchanged strings
  every frame repeats that work on each call; cache placements per string.
- The first placement of glyphs never seen builds their outlines. Place the strings a screen needs at load time to pay that
  up front.
- Outline capacity is fixed per font and does not grow.

## Credits

The glyph shader ports the reference pixel shader of Eric Lengyel's Slug algorithm
([github.com/EricLengyel/Slug](https://github.com/EricLengyel/Slug)), MIT licensed (`LICENSE-slug.txt`); the Slug patent is
dedicated to the public domain. Fonts are parsed and rasterized with stb_truetype v1.26 by Sean Barrett ([csrc/README.md](../csrc/README.md)).

## See also

- [Overlay list](overlay.md) for drawing glyph runs with rectangles and shapes.
- [GUI overlay](gui.md) for the ImGui adapter, whose fonts are not asset-store fonts.
- The [UI package README](../addons/c3d_ui.c3l/README.md) for font sets and cached placements.
