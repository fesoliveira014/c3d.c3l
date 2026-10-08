module c3d::asset;

import c3d;
import c3d::asset::truetype @public;
import c3d::pool;
import std::core::string::conv;
import std::math;

<*
 Pool of font records addressed by FontId.
*>
alias FontPool = Pool{FontAsset, FontId};

<*
 Texels per row of a font's curve and band storage.
*>
const uint FONT_TEXTURE_WIDTH = 4096; // mirrored as FONT_TEXTURE_WIDTH in abi/c3d.abi

<*
 Rows a font's curve or band storage may span.
*>
const uint FONT_MAX_ROWS = 4096; // Vulkan guarantees 2D images of 4096 texels per side

<*
 Glyph outlines a font keeps by default.
*>
const uint FONT_DEFAULT_MAX_GLYPHS = 5120; // one 32 B table entry each; the committed CJK subset has 4,197 glyphs

<*
 Curve texels a font reserves by default.
*>
const uint FONT_DEFAULT_CURVE_TEXELS = 96 * FONT_TEXTURE_WIDTH; // 6 MiB stored, 3 MiB on GPU; CJK subset: 70 rows

<*
 Band texels a font reserves by default.
*>
const uint FONT_DEFAULT_BAND_TEXELS = 384 * FONT_TEXTURE_WIDTH; // 6 MiB stored and on GPU; CJK subset: 278 rows

<*
 glyph_slots value of a glyph known to have no outline.
*>
const uint FONT_GLYPH_EMPTY = uint::max;

<*
 Face selection and outline capacities of one font.
*>
struct FontDesc {
    uint face_index;   // face within a collection; zero for a single-face file
    uint max_glyphs;
    uint curve_texels; // rounded up to whole rows
    uint band_texels;  // rounded up to whole rows
}

<*
 Vertical metrics in em units.
*>
struct FontMetrics {
    float ascent;
    float descent;  // negative below the baseline
    float line_gap;
}

<*
 One glyph of a line, placed in em units from the line origin.
*>
struct GlyphPlacement {
    uint glyph;     // glyph index in the font
    Vec2 position;  // x right, y down from the baseline origin
}

<*
 Width and vertical extent of one measured line in pixels.
*>
struct TextExtent {
    float width;
    float ascent;
    float descent;  // negative below the baseline
}

<*
 Pixel box of a rasterized glyph around its pen position, y down.
*>
struct GlyphBitmapBox {
    int min_x;
    int min_y;
    int max_x;
    int max_y;
}

<*
 Outline record of one built glyph.
*>
struct FontGlyph {
    Vec4 bounds;        // em, y up: min x, min y, max x, max y
    uint band_location; // first band texel: column | row << 16
    uint band_max;      // last vertical band index | last horizontal band index << 16
}

<*
 Font file, parsed face and outline storage owned by the store.
*>
struct FontAsset {
    AssetHeader header;
    char[]      file;
    FontDesc    desc;
    FontInfo    face;          // parsed by stb_truetype; points into file
    float       em_scale;      // em units per font unit
    FontMetrics metrics;
    char[]      storage;       // one allocation behind the four slices below
    Vec4[]      curves;        // curve texels in em units: x1, y1, x2, y2
    FontGlyph[] glyphs;        // built outlines in build order
    uint[]      bands;         // band texels: two u16 values, low half first
    uint[]      glyph_slots;   // per font glyph: index in glyphs plus one, FONT_GLYPH_EMPTY, or zero when unknown
    uint        glyph_count;
    uint        curve_texels;  // used
    uint        band_texels;   // used
}

struct TextPen @private {
    int position; // font units
    int previous; // glyph of the previous code point; negative before the first
}

<*
 Add a font, copying the file bytes into the store.
 @param file : "TrueType, OpenType or collection bytes; borrowed for the call."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn FontId? AssetStore.add_font(&self, char[] file, FontDesc desc, String key = "") {
    char[] copy = copy_slice(self.allocator, file);
    defer catch alloc::free(self.allocator, copy.ptr);
    return insert_font(self, copy, desc, key);
}

<*
 Add a font, taking its file bytes on success.
 @param file : "Allocated with the store allocator; the caller keeps it on a fault."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
*>
fn FontId? AssetStore.add_font_owned(&self, char[] file, FontDesc desc, String key = "") {
    return insert_font(self, file, desc, key);
}

<*
 Replace the font with a copy of the file; built glyphs are discarded.
 @param file : "TrueType, OpenType or collection bytes; borrowed for the call."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT
 @require self.fonts.is_live(font)
*>
fn void? AssetStore.replace_font(
    &self,
    FontId font,
    char[] file,
    FontDesc desc,
) {
    char[] copy = copy_slice(self.allocator, file);
    defer catch alloc::free(self.allocator, copy.ptr);
    return replace_font_record(self, font, copy, desc);
}

<*
 Replace the font, taking the file bytes on success.
 @param file : "Allocated with the store allocator; the caller keeps it on a fault."
 @return? c3d::ASSET_FORMAT_ERROR, c3d::UNSUPPORTED, c3d::INVALID_ARGUMENT
 @require self.fonts.is_live(font)
*>
fn void? AssetStore.replace_font_owned(
    &self,
    FontId font,
    char[] file,
    FontDesc desc,
) {
    return replace_font_record(self, font, file, desc);
}

<*
 Record of the font; a borrow into the pool.
 @require self.fonts.is_live(font)
*>
fn FontAsset* AssetStore.font(&self, FontId font) {
    return self.fonts.get(font);
}

<*
 Free the font's file and outlines and make its id stale.
 @require self.fonts.is_live(font)
*>
fn void AssetStore.remove_font(&self, FontId font) {
    FontAsset* record = self.fonts.get(font);
    forget_key(self, record.header.key);
    free_string(self.allocator, record.header.key);
    free_font(self.allocator, record);
    *record = {};
    self.fonts.remove(font);
}

<*
 Font id under a key.
 @return? NOT_FOUND, c3d::INVALID_ARGUMENT
*>
fn FontId? AssetStore.find_font(&self, String key) {
    AssetRef found = self.find(key)!;
    if (found.kind != AssetKind.FONT) return c3d::INVALID_ARGUMENT~;
    return (FontId){ .index = found.id.index, .generation = found.id.generation };
}

<*
 Vertical metrics of the font.
 @require self.fonts.is_live(font)
*>
fn FontMetrics AssetStore.font_metrics(&self, FontId font) {
    return self.font(font).metrics;
}

<*
 Glyph the font maps a code point to.
 @return? NOT_FOUND
 @require self.fonts.is_live(font)
*>
fn uint? AssetStore.find_glyph(&self, FontId font, Char32 code_point) {
    uint glyph = font_glyph(self.font(font), code_point);
    if (!glyph) return NOT_FOUND~;
    return glyph;
}

<*
 Width and vertical extent of one line of UTF-8 text.
 Builds no outlines.
 @return? c3d::INVALID_ARGUMENT
 @require self.fonts.is_live(font), size_pixels > 0
*>
fn TextExtent? AssetStore.measure_text(
    &self,
    FontId font,
    String text,
    float size_pixels,
) {
    FontAsset* record = self.font(font);
    TextPen pen = { .previous = -1 };
    usz offset;
    while (offset < text.len) {
        advance_pen(record, &pen, font_glyph(record, next_code_point(text, &offset)!));
    }

    return {
        .width   = (float)pen.position * record.em_scale * size_pixels,
        .ascent  = record.metrics.ascent * size_pixels,
        .descent = record.metrics.descent * size_pixels,
    };
}

<*
 Place one line of UTF-8 text and build outlines for its new glyphs.
 Advances the font revision when it builds outlines.
 @param [out] placements : "Receives one entry per glyph with an outline."
 @return "Placements written."
 @return? c3d::INVALID_ARGUMENT, c3d::CAPACITY_EXCEEDED
 @require self.fonts.is_live(font)
*>
fn usz? AssetStore.place_text(
    &self,
    FontId font,
    String text,
    GlyphPlacement[] placements,
) {
    FontAsset* record = self.font(font);
    usz visible;
    usz offset;
    while (offset < text.len) {
        if (glyph_has_outline(record, font_glyph(record, next_code_point(text, &offset)!))) visible++;
    }
    if (visible > placements.len) return c3d::CAPACITY_EXCEEDED~;

    bool built;
    defer if (built) record.header.revision++;
    TextPen pen = { .previous = -1 };
    usz written;
    offset = 0;
    while (offset < text.len) {
        uint glyph = font_glyph(record, next_code_point(text, &offset)!);
        int origin = advance_pen(record, &pen, glyph);
        if (record.glyph_slots[glyph] == FONT_GLYPH_EMPTY) continue;

        if (!record.glyph_slots[glyph]) {
            build_glyph(record, glyph)!;
            built = true;
        }
        placements[written] = { .glyph = glyph, .position = { (float)origin * record.em_scale, 0 } };
        written++;
    }
    return written;
}

<*
 Pixel box rasterize_glyph fills for the glyph at a size.
 @param subpixel : "Pen offset in pixels, each component in [0, 1)."
 @require self.fonts.is_live(font), glyph < self.font(font).glyph_slots.len, size_pixels > 0
*>
fn GlyphBitmapBox AssetStore.glyph_bitmap_box(
    &self,
    FontId font,
    uint glyph,
    float size_pixels,
    Vec2 subpixel,
) {
    FontAsset* record = self.font(font);
    float scale = size_pixels * record.em_scale;
    GlyphBitmapBox box;
    truetype::get_glyph_bitmap_box_subpixel(
        info:    &record.face,
        glyph:   (int)glyph,
        scale_x: scale,
        scale_y: scale,
        shift_x: subpixel.x,
        shift_y: subpixel.y,
        min_x:   &box.min_x,
        min_y:   &box.min_y,
        max_x:   &box.max_x,
        max_y:   &box.max_y,
    );
    return box;
}

<*
 Rasterize the glyph's coverage with stb_truetype, one byte per pixel.
 @param subpixel : "Pen offset in pixels, each component in [0, 1)."
 @param [out] coverage : "Rows of the glyph_bitmap_box width, top row first."
 @require self.fonts.is_live(font), glyph < self.font(font).glyph_slots.len, size_pixels > 0
 @require coverage.len >= glyph_bitmap_area(self.glyph_bitmap_box(font, glyph, size_pixels, subpixel))
*>
fn void AssetStore.rasterize_glyph(
    &self,
    FontId font,
    uint glyph,
    float size_pixels,
    Vec2 subpixel,
    char[] coverage,
) {
    FontAsset* record = self.font(font);
    float scale = size_pixels * record.em_scale;
    GlyphBitmapBox box = self.glyph_bitmap_box(
        font:        font,
        glyph:       glyph,
        size_pixels: size_pixels,
        subpixel:    subpixel,
    );
    int width = box.max_x - box.min_x;
    truetype::make_glyph_bitmap_subpixel(
        info:    &record.face,
        output:  coverage.ptr,
        width:   width,
        height:  box.max_y - box.min_y,
        stride:  width,
        scale_x: scale,
        scale_y: scale,
        shift_x: subpixel.x,
        shift_y: subpixel.y,
        glyph:   (int)glyph,
    );
}

<*
 Default face and outline capacities.
*>
fn FontDesc default_font_desc() {
    return {
        .max_glyphs   = FONT_DEFAULT_MAX_GLYPHS,
        .curve_texels = FONT_DEFAULT_CURVE_TEXELS,
        .band_texels  = FONT_DEFAULT_BAND_TEXELS,
    };
}

fn FontId? insert_font(AssetStore* store, char[] file, FontDesc desc, String key) @private {
    check_key(store, key)!;
    FontAsset body = build_font(store.allocator, file, desc)!;
    defer catch alloc::free(store.allocator, body.storage.ptr);
    FontId id = store.fonts.add({})!;
    body.header = { .key = copy_string(store.allocator, key), .revision = 1 };
    *store.fonts.get(id) = body;
    register_key(store, key, typed_ref(AssetKind.FONT, id));
    return id;
}

fn void? replace_font_record(AssetStore* store, FontId font, char[] file, FontDesc desc) @private {
    FontAsset* record = store.fonts.get(font);
    FontAsset body = build_font(store.allocator, file, desc)!;
    body.header = record.header;
    free_font(store.allocator, record);
    *record = body;
    mark_replaced(&record.header);
}

fn FontAsset? build_font(Allocator allocator, char[] file, FontDesc desc) @private {
    if (!font_capacity_valid(desc)) return c3d::INVALID_ARGUMENT~;
    uint offset = check_sfnt(file, desc.face_index)!;
    FontInfo face;
    if (!truetype::init_font(&face, file.ptr, (int)offset) || face.glyph_count <= 0) return c3d::ASSET_FORMAT_ERROR~;

    int ascent;
    int descent;
    int line_gap;
    truetype::get_font_v_metrics(
        info:     &face,
        ascent:   &ascent,
        descent:  &descent,
        line_gap: &line_gap,
    );
    float em_scale = truetype::scale_for_mapping_em_to_pixels(&face, 1);

    uint curve_texels = round_up_rows(desc.curve_texels);
    uint band_texels = round_up_rows(desc.band_texels);
    usz glyphs_offset = (usz)curve_texels * Vec4::size;
    usz bands_offset = glyphs_offset + (usz)desc.max_glyphs * FontGlyph::size;
    usz slots_offset = bands_offset + (usz)band_texels * uint::size;
    usz total_bytes = slots_offset + (usz)face.glyph_count * uint::size;
    // Allocated as Vec4 so every allocator aligns the block for the Vec4 members of the carved slices.
    Vec4[] block = alloc::new_array(allocator, Vec4, (sz)((total_bytes + Vec4::size - 1) / Vec4::size));
    char[] storage = ((char*)block.ptr)[:total_bytes];

    return {
        .file        = file,
        .desc        = desc,
        .face        = face,
        .em_scale    = em_scale,
        .metrics     = {
            .ascent   = (float)ascent * em_scale,
            .descent  = (float)descent * em_scale,
            .line_gap = (float)line_gap * em_scale,
        },
        .storage     = storage,
        .curves      = ((Vec4*)storage.ptr)[:curve_texels],
        .glyphs      = ((FontGlyph*)&storage[glyphs_offset])[:desc.max_glyphs],
        .bands       = ((uint*)&storage[bands_offset])[:band_texels],
        .glyph_slots = ((uint*)&storage[slots_offset])[:face.glyph_count],
    };
}

fn void free_font(Allocator allocator, FontAsset* font) @private {
    alloc::free(allocator, font.file.ptr);
    alloc::free(allocator, font.storage.ptr);
}

fn bool font_capacity_valid(FontDesc desc) @local {
    uint limit = FONT_TEXTURE_WIDTH * FONT_MAX_ROWS;
    return desc.max_glyphs > 0 && desc.curve_texels > 0 && desc.band_texels > 0
        && desc.curve_texels <= limit && desc.band_texels <= limit;
}

fn uint round_up_rows(uint texels) @local {
    return (texels + FONT_TEXTURE_WIDTH - 1) / FONT_TEXTURE_WIDTH * FONT_TEXTURE_WIDTH;
}

// stb_truetype returns cmap glyph ids unchecked; an id past the face's glyphs reads as missing.
fn uint font_glyph(FontAsset* font, Char32 code_point) @private {
    int glyph = truetype::find_glyph_index(&font.face, (int)code_point);
    return glyph > 0 && glyph < font.glyph_slots.len ? (uint)glyph : 0;
}

// stbtt_IsGlyphEmpty runs a whole CFF charstring, so the answer is cached in the slot.
fn bool glyph_has_outline(FontAsset* font, uint glyph) @private {
    uint slot = font.glyph_slots[glyph];
    if (slot) return slot != FONT_GLYPH_EMPTY;
    if (!truetype::is_glyph_empty(&font.face, (int)glyph)) return true;

    font.glyph_slots[glyph] = FONT_GLYPH_EMPTY;
    return false;
}

fn int advance_pen(FontAsset* font, TextPen* pen, uint glyph) @local {
    if (pen.previous >= 0) pen.position += truetype::get_glyph_kern_advance(&font.face, pen.previous, (int)glyph);
    int origin = pen.position;

    int advance;
    int bearing;
    truetype::get_glyph_h_metrics(
        info:              &font.face,
        glyph:             (int)glyph,
        advance_width:     &advance,
        left_side_bearing: &bearing,
    );
    pen.position += advance;
    pen.previous = (int)glyph;
    return origin;
}

fn Char32? next_code_point(String text, usz* offset) @local {
    sz size = (sz)(text.len - *offset);
    Char32? decoded = conv::utf8_to_char32(&text[*offset], &size);
    if (catch decoded) return c3d::INVALID_ARGUMENT~;
    *offset += (usz)size;
    return decoded;
}

fn usz glyph_bitmap_area(GlyphBitmapBox box) @private {
    return (usz)(box.max_x - box.min_x) * (usz)(box.max_y - box.min_y);
}
